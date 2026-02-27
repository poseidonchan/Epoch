import Combine
import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

@MainActor
public final class AppStore: ObservableObject {
    internal enum DefaultsKey {
        static let gatewayDeviceID = "LabOS.gateway.deviceID"
        static let gatewayWSURL = "LabOS.gateway.wsURL"
        static let gatewayToken = "LabOS.gateway.token"
        static let backendEngine = "LabOS.backend.engine"
        static let hpcPartition = "LabOS.hpc.partition"
        static let hpcAccount = "LabOS.hpc.account"
        static let hpcQos = "LabOS.hpc.qos"
        static let runCompletionNotificationsEnabled = "LabOS.notifications.runCompletion.enabled"
        static let codexPromptDraftPrefix = "LabOS.codexPromptDraft"
        static let codexTrajectoryDurations = "LabOS.codexTrajectoryDurations"
        static let codexQueuedInputPrefix = "LabOS.codexQueuedInput"
    }

    public struct RunCompletionSignal: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let projectID: UUID
        public let runID: UUID
        public let sessionID: UUID?
        public let projectName: String
        public let status: RunStatus
        public let completedAt: Date

        public init(
            id: UUID = UUID(),
            projectID: UUID,
            runID: UUID,
            sessionID: UUID?,
            projectName: String,
            status: RunStatus,
            completedAt: Date
        ) {
            self.id = id
            self.projectID = projectID
            self.runID = runID
            self.sessionID = sessionID
            self.projectName = projectName
            self.status = status
            self.completedAt = completedAt
        }
    }

    public struct PendingUserInputSignal: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let projectID: UUID
        public let sessionID: UUID
        public let requestID: CodexRequestID
        public let projectName: String
        public let sessionTitle: String
        public let promptText: String?
        public let createdAt: Date

        public init(
            id: UUID = UUID(),
            projectID: UUID,
            sessionID: UUID,
            requestID: CodexRequestID,
            projectName: String,
            sessionTitle: String,
            promptText: String?,
            createdAt: Date = .now
        ) {
            self.id = id
            self.projectID = projectID
            self.sessionID = sessionID
            self.requestID = requestID
            self.projectName = projectName
            self.sessionTitle = sessionTitle
            self.promptText = promptText
            self.createdAt = createdAt
        }
    }

    public struct CodexPromptDraftState: Codable, Hashable, Sendable {
        public var questionIndex: Int
        public var selectedOptionByQuestionID: [String: String]
        public var freeformByQuestionID: [String: String]

        public init(
            questionIndex: Int = 0,
            selectedOptionByQuestionID: [String: String] = [:],
            freeformByQuestionID: [String: String] = [:]
        ) {
            self.questionIndex = questionIndex
            self.selectedOptionByQuestionID = selectedOptionByQuestionID
            self.freeformByQuestionID = freeformByQuestionID
        }
    }

    public struct ArtifactStorageBucket: Identifiable, Hashable, Sendable {
        public var id: ArtifactKind { kind }
        public let kind: ArtifactKind
        public let bytes: Int
        public let itemCount: Int

        public init(kind: ArtifactKind, bytes: Int, itemCount: Int) {
            self.kind = kind
            self.bytes = bytes
            self.itemCount = itemCount
        }
    }

    @Published public internal(set) var projects: [Project] = []
    @Published public internal(set) var sessionsByProject: [UUID: [Session]] = [:]
    @Published public internal(set) var artifactsByProject: [UUID: [Artifact]] = [:]
    @Published public internal(set) var runsByProject: [UUID: [RunRecord]] = [:]
    @Published public internal(set) var messagesBySession: [UUID: [ChatMessage]] = [:]
    @Published public internal(set) var codexItemsBySession: [UUID: [CodexThreadItem]] = [:]
    @Published public internal(set) var codexProposedPlanTextBySession: [UUID: [String: String]] = [:]
    @Published public internal(set) var codexPendingApprovalsBySession: [UUID: [CodexPendingApproval]] = [:]
    @Published public internal(set) var codexPendingPromptBySession: [UUID: [CodexPendingPrompt]] = [:]
    @Published public internal(set) var codexQueuedInputsBySession: [UUID: [CodexQueuedUserInputItem]] = [:]
    @Published public internal(set) var codexActiveTurnIDBySession: [UUID: String] = [:]
    @Published public internal(set) var codexStatusTextBySession: [UUID: String] = [:]
    @Published public internal(set) var codexTurnDiffBySession: [UUID: CodexTurnDiffState] = [:]
    @Published public internal(set) var codexSkillsStateBySession: [UUID: CodexSkillsListState] = [:]
    @Published public internal(set) var codexTokenUsageBySession: [UUID: CodexTokenUsage] = [:]
    @Published public internal(set) var codexFullAccessBySession: [UUID: Bool] = [:]
    @Published public internal(set) var codexTrajectoryStartedAtBySession: [UUID: [String: Date]] = [:]
    @Published public internal(set) var codexStagedImageURLBySession: [UUID: [String: String]] = [:]

    @Published public internal(set) var streamingSessions: Set<UUID> = []
    @Published public internal(set) var streamingAssistantMessageIDBySession: [UUID: UUID] = [:]

    @Published public internal(set) var activeProvider: String?
    @Published public internal(set) var availableModels: [GatewayModelInfo] = []
    @Published public internal(set) var defaultModelId: String?
    @Published public internal(set) var availableThinkingLevels: [ThinkingLevel] = []

    @Published public internal(set) var planModeEnabledBySession: [UUID: Bool] = [:]
    @Published public internal(set) var selectedModelIdBySession: [UUID: String] = [:]
    @Published public internal(set) var selectedThinkingLevelBySession: [UUID: ThinkingLevel] = [:]
    @Published public internal(set) var permissionLevelBySession: [UUID: SessionPermissionLevel] = [:]
    @Published public internal(set) var pendingComposerAttachmentsBySession: [UUID: [ComposerAttachment]] = [:]

    @Published public internal(set) var livePlanBySession: [UUID: AgentPlanUpdatedPayload] = [:]
    @Published public internal(set) var liveAgentEventsBySession: [UUID: [AgentLiveEvent]] = [:]
    @Published public internal(set) var activeInlineProcessBySession: [UUID: ActiveInlineProcess] = [:]
    @Published public internal(set) var persistedProcessSummaryByMessageID: [UUID: AssistantProcessSummary] = [:]

    @Published public internal(set) var sessionContextBySession: [UUID: SessionContextState] = [:]

    internal var codexTrajectoryDurationsBySession: [UUID: [String: Int]] = [:]
    internal var codexQueuedInputsLoadedSessions: Set<UUID> = []
    private var codexSuppressedTurnIDsBySession: [UUID: Set<String>] = [:]
    private var codexFirstUserMessageIDByScopedBackendTurn: [String: String] = [:]
    private var codexTurnStartedAtByScopedBackendTurn: [String: Date] = [:]
    private var codexPendingDurationMsByScopedBackendTurn: [String: Int] = [:]
    private var codexCommandNoResultStartedAtBySession: [UUID: [String: Date]] = [:]
    private var codexInterruptedTurnIDsBySession: [UUID: Set<String>] = [:]
    private var codexStagedImageInflightKeysBySession: [UUID: Set<String>] = [:]

    @Published public var resourceStatus: ResourceStatus = .placeholder

    @Published public internal(set) var gatewayConnectionState: GatewayConnectionState = .disconnected
    @Published public internal(set) var codexConnectionState: CodexConnectionState = .disconnected
    @Published public var gatewayWSURLString: String = ""
    @Published public var gatewayToken: String = ""
    @Published public var preferredBackendEngine: String = "codex-app-server"

    @Published public var hpcPartition: String = ""
    @Published public var hpcAccount: String = ""
    @Published public var hpcQos: String = ""

    @Published public var activeProjectID: UUID?
    @Published public var activeSessionID: UUID?

    @Published public internal(set) var lastGatewayErrorMessage: String?

    @Published public var isLeftPanelOpen = false
    @Published public var isRightPanelOpen = false
    @Published public var rightPanelTab: ResultsTab = .artifacts
    @Published public var selectedArtifactPath: String?
    @Published public var highlightedArtifactPath: String?
    @Published public var selectedRunID: UUID?
    @Published public internal(set) var runCompletionNotificationsEnabled = true
    @Published public internal(set) var latestRunCompletionSignal: RunCompletionSignal?
    @Published public internal(set) var latestPendingUserInputSignal: PendingUserInputSignal?

    // MARK: - Internal Services (initialized in init)
    internal var composerService: ComposerService!
    internal var projectService: ProjectService!
    internal var planService: PlanApprovalService!
    internal var chatService: ChatSessionService!

    enum SessionHistoryRefreshTrigger {
        case interactive
        case prefetch
    }


    public struct ProjectUploadFile: Sendable {
        public var fileName: String
        public var data: Data
        public var mimeType: String?

        public init(fileName: String, data: Data, mimeType: String? = nil) {
            self.fileName = fileName
            self.data = data
            self.mimeType = mimeType
        }
    }

    internal struct GatewayUploadResponse: Decodable, Sendable {
        var uploadId: String
        var path: String
    }
    internal var artifactContentCache: [String: String] = [:]
    internal var artifactDataCache: [String: Data] = [:]
    internal let backend: BackendClient
    internal let defaults: UserDefaults
    internal var gatewayClient: GatewayClient?
    internal var codexClient: CodexRPCClient?
    private var gatewayEventsTask: Task<Void, Never>?
    private var codexNotificationsTask: Task<Void, Never>?
    private var codexServerRequestsTask: Task<Void, Never>?
    private var gatewayStateCancellable: AnyCancellable?
    private var gatewayEnsureConnectedTask: Task<Bool, Never>?
    private var codexEnsureConnectedTask: Task<Bool, Never>?
    internal var gatewayDeviceID: UUID = UUID()
    private var resourcesPollTask: Task<Void, Never>?
    private var homeRunsPollTask: Task<Void, Never>?
    internal var codexThreadBySession: [UUID: String] = [:]
    internal var codexSessionByThread: [String: UUID] = [:]
    internal var codexPendingThreadBindingSessions: Set<UUID> = []
    internal var codexRequestOverrideForTests: ((_ method: String, _ params: JSONValue?) async throws -> CodexRPCResponse)?
    internal var codexServerResponseOverrideForTests: ((_ id: CodexRequestID, _ result: JSONValue?, _ error: CodexRPCError?) -> Void)?

    internal let gatewayJSONEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    internal let gatewayJSONDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    internal let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = [.dropLeading, .dropTrailing]
        return formatter
    }()
    public init(backend: BackendClient = MockBackendClient(), bootstrapDemo: Bool = true, userDefaults: UserDefaults = .standard) {
        self.backend = backend
        defaults = userDefaults
        loadGatewaySettings()
        loadCodexTrajectoryDurations()

        // Initialize services
        composerService = ComposerService(store: self)
        projectService = ProjectService(store: self)
        planService = PlanApprovalService(store: self)
        chatService = ChatSessionService(store: self)

        composerService.loadHpcSettings()
        composerService.loadNotificationSettings()

        if bootstrapDemo, !isGatewayConfigured {
            seedDemoData()
        }

        // Fixture activation is environment-gated internally, so it is safe to
        // evaluate in all launches (including UI tests where XCTestConfigurationFilePath
        // is not propagated into the app process).
        applyE2EFixturesIfNeeded()

        if bootstrapDemo, isGatewayConfigured, !isRunningTests {
            Task { [weak self] in
                await self?.connectGateway()
            }
        }
    }

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    public var isGatewayConfigured: Bool {
        !gatewayWSURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !gatewayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isGatewayConnected: Bool {
        if case .connected = gatewayConnectionState { return true }
        return false
    }

    public var isCodexConnected: Bool {
        if case .connected = codexConnectionState { return true }
        return false
    }

    public var shouldUseCodexRPC: Bool {
        isCodexConnected
    }

    public var hpcStorageRemainingPercent: Double {
        let remaining = 100 - resourceStatus.storageUsedPercent
        return min(max(remaining, 0), 100)
    }

    public var hpcStorageTotalBytes: Int64? {
        resourceStatus.storageTotalBytes
    }

    public var hpcStorageUsedBytes: Int64? {
        resourceStatus.storageUsedBytes
    }

    public var hpcStorageAvailableBytes: Int64? {
        resourceStatus.storageAvailableBytes
    }

    public var artifactStorageBreakdown: [ArtifactStorageBucket] {
        var grouped: [ArtifactKind: (bytes: Int, count: Int)] = [:]

        for artifacts in artifactsByProject.values {
            for artifact in artifacts {
                let size = max(artifact.sizeBytes ?? 0, 0)
                var current = grouped[artifact.kind, default: (bytes: 0, count: 0)]
                current.bytes += size
                current.count += 1
                grouped[artifact.kind] = current
            }
        }

        return grouped
            .map { kind, usage in
                ArtifactStorageBucket(kind: kind, bytes: usage.bytes, itemCount: usage.count)
            }
            .sorted { lhs, rhs in
                if lhs.bytes == rhs.bytes {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                return lhs.bytes > rhs.bytes
            }
    }

    public var totalArtifactStorageBytes: Int {
        artifactStorageBreakdown.reduce(0) { partial, row in
            partial + row.bytes
        }
    }

    private func loadGatewaySettings() {
        if let rawID = defaults.string(forKey: DefaultsKey.gatewayDeviceID),
           let parsed = UUID(uuidString: rawID) {
            gatewayDeviceID = parsed
        } else {
            gatewayDeviceID = UUID()
            defaults.set(gatewayDeviceID.uuidString, forKey: DefaultsKey.gatewayDeviceID)
        }

        gatewayWSURLString = defaults.string(forKey: DefaultsKey.gatewayWSURL) ?? ""
        gatewayToken = defaults.string(forKey: DefaultsKey.gatewayToken) ?? ""
        preferredBackendEngine = normalizeBackendEngine(defaults.string(forKey: DefaultsKey.backendEngine)) ?? "codex-app-server"
    }

    private func loadCodexTrajectoryDurations() {
        guard let data = defaults.data(forKey: DefaultsKey.codexTrajectoryDurations) else {
            codexTrajectoryDurationsBySession = [:]
            return
        }

        guard let decoded = try? gatewayJSONDecoder.decode([String: [String: Int]].self, from: data) else {
            codexTrajectoryDurationsBySession = [:]
            return
        }

        var mapped: [UUID: [String: Int]] = [:]
        for (sessionIDRaw, turnDurations) in decoded {
            guard let sessionID = UUID(uuidString: sessionIDRaw) else { continue }
            let cleaned = turnDurations.filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value > 0 }
            if !cleaned.isEmpty {
                mapped[sessionID] = cleaned
            }
        }
        codexTrajectoryDurationsBySession = mapped
    }

    private func persistCodexTrajectoryDurations() {
        let encodedMap = codexTrajectoryDurationsBySession.reduce(into: [String: [String: Int]]()) { result, entry in
            let durations = entry.value.filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.value > 0 }
            guard !durations.isEmpty else { return }
            result[entry.key.uuidString.lowercased()] = durations
        }

        if encodedMap.isEmpty {
            defaults.removeObject(forKey: DefaultsKey.codexTrajectoryDurations)
            return
        }

        if let data = try? gatewayJSONEncoder.encode(encodedMap) {
            defaults.set(data, forKey: DefaultsKey.codexTrajectoryDurations)
        }
    }

    public func setRunCompletionNotificationsEnabled(_ enabled: Bool) {
        composerService.setRunCompletionNotificationsEnabled(enabled)
    }

    public func saveGatewaySettings(wsURLString: String, token: String) {
        let trimmedURL = wsURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = Self.normalizedGatewayWSURLString(trimmedURL) ?? trimmedURL
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        gatewayWSURLString = normalizedURL
        gatewayToken = trimmedToken
        defaults.set(normalizedURL, forKey: DefaultsKey.gatewayWSURL)
        defaults.set(trimmedToken, forKey: DefaultsKey.gatewayToken)
    }

    public func savePreferredBackendEngine(_ backendEngine: String) {
        let normalized = normalizeBackendEngine(backendEngine) ?? "codex-app-server"
        preferredBackendEngine = normalized
        defaults.set(normalized, forKey: DefaultsKey.backendEngine)
    }

    public func saveHpcSettings(partition: String, account: String, qos: String) {
        composerService.saveHpcSettings(partition: partition, account: account, qos: qos)
    }

    public func pushHpcPreferencesToGateway() {
        composerService.pushHpcPreferencesToGateway()
    }

    internal func normalizedOptionalString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    internal func normalizeBackendEngine(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "pi" || normalized == "pi-adapter" {
            return "codex-app-server"
        }
        if normalized == "codex" || normalized == "codex-app-server" {
            return "codex-app-server"
        }
        return nil
    }

    public func connectGateway() async {
        guard isGatewayConfigured else { return }

        let normalizedURLString = Self.normalizedGatewayWSURLString(gatewayWSURLString) ?? gatewayWSURLString
        guard let wsURL = URL(string: normalizedURLString) else {
            lastGatewayErrorMessage = "Invalid gateway URL. Use ws://host:8787/ws"
            gatewayConnectionState = .failed(message: "Invalid gateway URL. Use ws://host:8787/ws")
            return
        }

        disconnectGateway()

        let client = GatewayClient(wsURL: wsURL, token: gatewayToken, deviceID: gatewayDeviceID, deviceName: "LabOS iPhone")
        gatewayClient = client
        gatewayStateCancellable = client.$connectionState.sink { [weak self] state in
            self?.gatewayConnectionState = state
        }

        await client.connect()
        if isGatewayConnected {
            lastGatewayErrorMessage = nil
            await composerService.refreshModelsFromGateway()
            composerService.pushHpcPreferencesToGateway()
            startGatewayEventLoop()
            startResourcePolling()
            startHomeRunsPolling()
        }

        await connectCodex()

        if isCodexConnected {
            await refreshProjectsFromCodex()
        } else if isGatewayConnected {
            await refreshProjectsFromGateway()
        } else {
            lastGatewayErrorMessage = "Unable to connect to /ws or /codex."
        }
    }

    // Best-effort connect for chat sends. Avoids resetting local project/session UI state.
    internal func ensureGatewayConnectedForChat() async -> Bool {
        if isGatewayConnected { return true }
        guard isGatewayConfigured else { return false }

        if let task = gatewayEnsureConnectedTask {
            return await task.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.gatewayEnsureConnectedTask = nil }

            let normalizedURLString = Self.normalizedGatewayWSURLString(self.gatewayWSURLString) ?? self.gatewayWSURLString
            guard let wsURL = URL(string: normalizedURLString) else {
                self.lastGatewayErrorMessage = "Invalid gateway URL. Use ws://host:8787/ws"
                self.gatewayConnectionState = .failed(message: "Invalid gateway URL. Use ws://host:8787/ws")
                return false
            }

            let client: GatewayClient
            if let existing = self.gatewayClient {
                client = existing
            } else {
                let newClient = GatewayClient(wsURL: wsURL, token: self.gatewayToken, deviceID: self.gatewayDeviceID, deviceName: "LabOS iPhone")
                self.gatewayClient = newClient
                self.gatewayStateCancellable?.cancel()
                self.gatewayStateCancellable = newClient.$connectionState.sink { [weak self] state in
                    self?.gatewayConnectionState = state
                }
                client = newClient
            }

            if !self.isGatewayConnected {
                client.disconnect()
                await client.connect()
            }

            guard self.isGatewayConnected else { return false }

            self.startGatewayEventLoop()
            self.startResourcePolling()
            self.startHomeRunsPolling()
            await self.composerService.refreshModelsFromGateway()
            self.composerService.pushHpcPreferencesToGateway()

            self.lastGatewayErrorMessage = nil
            return self.isGatewayConnected
        }

        gatewayEnsureConnectedTask = task
        return await task.value
    }

    internal func ensureCodexConnectedForChat() async -> Bool {
        if isCodexConnected { return true }
        guard isGatewayConfigured else { return false }

        if let task = codexEnsureConnectedTask {
            return await task.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.codexEnsureConnectedTask = nil }

            if !self.isGatewayConnected {
                let gatewayReady = await self.ensureGatewayConnectedForChat()
                guard gatewayReady else { return false }
            }

            await self.connectCodex()
            if self.isCodexConnected {
                self.lastGatewayErrorMessage = nil
            }
            return self.isCodexConnected
        }

        codexEnsureConnectedTask = task
        return await task.value
    }

    private static func normalizedGatewayWSURLString(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Accept common inputs like:
        // - "127.0.0.1:8787"
        // - "https://127.0.0.1:8787"
        // - "HTTPS 127.0.0.1:8787"
        if !value.contains("://") {
            let parts = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count == 2, ["http", "https", "ws", "wss"].contains(parts[0].lowercased()) {
                value = "\(parts[0].lowercased())://\(parts[1])"
            } else {
                value = "ws://\(value)"
            }
        }

        guard var components = URLComponents(string: value) else { return nil }
        let scheme = components.scheme?.lowercased() ?? ""
        switch scheme {
        case "ws":
            break
        case "wss":
            // Local dev hubs typically run without TLS; if a user pasted https/wss for the
            // default hub port, downgrade so the app can connect without extra setup.
            let host = (components.host ?? "").lowercased()
            if (host == "127.0.0.1" || host == "localhost"), (components.port == 8787 || components.port == nil) {
                components.scheme = "ws"
            }
        case "http", "https":
            // In v0.1 we default HTTP(S) -> WS because local dev hubs typically run without TLS,
            // and users commonly paste http(s) URLs here. Users who need TLS can enter wss://.
            components.scheme = "ws"
        default:
            return nil
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/ws"
        }

        return components.url?.absoluteString
    }

    internal static func gatewayID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    internal static let codexLocalUserItemPrefix = "local-user-"
    private static let codexImageBridgeDirectoryName = "labos-codex-image-bridge"
    private static let codexSupportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "bmp", "tiff", "tif", "avif",
    ]

    private struct CodexCommandExecParams: Codable, Sendable {
        var command: [String]
        var timeoutMs: Int?
        var cwd: String?
    }

    private struct CodexCommandExecResponse: Codable, Sendable {
        var exitCode: Int
        var stdout: String
        var stderr: String
    }

    static func sessionHistoryPrefetchCandidates(
        sessions: [Session],
        activeSessionID: UUID?,
        loadedMessageSessionIDs: Set<UUID>,
        inFlightSessionIDs: Set<UUID>,
        lastFetchedAtBySession: [UUID: Date],
        now: Date,
        cooldown: TimeInterval
    ) -> [UUID] {
        sessions
            .sorted { lhs, rhs in
                if lhs.lifecycle != rhs.lifecycle {
                    return lhs.lifecycle == .active
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.createdAt > rhs.createdAt
            }
            .compactMap { session in
                let sessionID = session.id
                if sessionID == activeSessionID {
                    return nil
                }
                if loadedMessageSessionIDs.contains(sessionID) {
                    return nil
                }
                if inFlightSessionIDs.contains(sessionID) {
                    return nil
                }
                if let lastFetched = lastFetchedAtBySession[sessionID],
                   now.timeIntervalSince(lastFetched) < cooldown {
                    return nil
                }
                return sessionID
            }
    }

    static func shouldSkipSessionHistoryRefresh(
        trigger: SessionHistoryRefreshTrigger,
        hasInFlightRequest: Bool,
        hasLocalMessages: Bool,
        hasStreamingState: Bool,
        hasInProgressStatus: Bool,
        hasTransientIncomplete: Bool,
        lastFetchedAt: Date?,
        now: Date,
        prefetchCooldown: TimeInterval,
        interactiveFreshnessWindow: TimeInterval
    ) -> Bool {
        if hasInFlightRequest {
            return true
        }

        guard let lastFetchedAt else {
            return false
        }

        let age = now.timeIntervalSince(lastFetchedAt)
        switch trigger {
        case .prefetch:
            return age < prefetchCooldown
        case .interactive:
            // If we already have local content from a fresh prefetch, skip immediate
            // re-fetch on open to avoid list repaint/flash.
            guard hasLocalMessages else { return false }
            if hasStreamingState || hasInProgressStatus || hasTransientIncomplete {
                return false
            }
            return age < interactiveFreshnessWindow
        }
    }

    static func shouldPublishResourceStatusUpdate(
        context: AppContext,
        previous: ResourceStatus,
        incoming: ResourceStatus
    ) -> Bool {
        guard case .home = context else { return false }
        return previous != incoming
    }

    public func disconnectGateway() {
        for (_, task) in chatService.sessionHistoryPrefetchTasksByProject {
            task.cancel()
        }
        chatService.sessionHistoryPrefetchTasksByProject.removeAll()
        gatewayEventsTask?.cancel()
        gatewayEventsTask = nil
        codexNotificationsTask?.cancel()
        codexNotificationsTask = nil
        codexServerRequestsTask?.cancel()
        codexServerRequestsTask = nil
        gatewayStateCancellable?.cancel()
        gatewayStateCancellable = nil
        gatewayEnsureConnectedTask?.cancel()
        gatewayEnsureConnectedTask = nil
        codexEnsureConnectedTask?.cancel()
        codexEnsureConnectedTask = nil
        resourcesPollTask?.cancel()
        resourcesPollTask = nil
        homeRunsPollTask?.cancel()
        homeRunsPollTask = nil
        gatewayClient?.disconnect()
        gatewayClient = nil
        codexClient?.disconnect()
        codexClient = nil
        gatewayConnectionState = .disconnected
        codexConnectionState = .disconnected
        planService.pendingApprovalsBySession.removeAll()
        planService.planSessionByPlanID.removeAll()
        livePlanBySession.removeAll()
        liveAgentEventsBySession.removeAll()
        activeInlineProcessBySession.removeAll()
        persistedProcessSummaryByMessageID.removeAll()
        planModeEnabledBySession.removeAll()
        selectedModelIdBySession.removeAll()
        selectedThinkingLevelBySession.removeAll()
        streamingSessions.removeAll()
        streamingAssistantMessageIDBySession.removeAll()
        codexItemsBySession.removeAll()
        codexProposedPlanTextBySession.removeAll()
        codexPendingApprovalsBySession.removeAll()
        codexPendingPromptBySession.removeAll()
        codexQueuedInputsBySession.removeAll()
        codexQueuedInputsLoadedSessions.removeAll()
        codexActiveTurnIDBySession.removeAll()
        codexStatusTextBySession.removeAll()
        codexTurnDiffBySession.removeAll()
        codexSkillsStateBySession.removeAll()
        codexTokenUsageBySession.removeAll()
        codexFullAccessBySession.removeAll()
        codexTrajectoryStartedAtBySession.removeAll()
        clearCodexStagedImages(sessionIDs: Set(codexStagedImageURLBySession.keys))
        codexStagedImageURLBySession.removeAll()
        codexStagedImageInflightKeysBySession.removeAll()
        codexCommandNoResultStartedAtBySession.removeAll()
        codexSuppressedTurnIDsBySession.removeAll()
        codexFirstUserMessageIDByScopedBackendTurn.removeAll()
        codexTurnStartedAtByScopedBackendTurn.removeAll()
        codexPendingDurationMsByScopedBackendTurn.removeAll()
        codexInterruptedTurnIDsBySession.removeAll()
        codexThreadBySession.removeAll()
        codexSessionByThread.removeAll()
        codexPendingThreadBindingSessions.removeAll()
        chatService.sessionHistoryRequestsInFlight.removeAll()
        chatService.sessionHistoryLastFetchedAtBySession.removeAll()
        latestPendingUserInputSignal = nil
    }

    private func startGatewayEventLoop() {
        guard let gatewayClient else { return }
        gatewayEventsTask?.cancel()
        gatewayEventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in gatewayClient.events {
                self.handleGatewayEvent(event)
            }
        }
    }

    private func startResourcePolling() {
        resourcesPollTask?.cancel()
        guard let base = gatewayHTTPBaseURL() else { return }

        resourcesPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    var req = URLRequest(url: base.appendingPathComponent("status/resources"))
                    req.setValue("Bearer \(self.gatewayToken)", forHTTPHeaderField: "Authorization")
                    let (data, _) = try await URLSession.shared.data(for: req)
                    let status = try self.gatewayJSONDecoder.decode(ResourceStatus.self, from: data)
                    if Self.shouldPublishResourceStatusUpdate(
                        context: self.context,
                        previous: self.resourceStatus,
                        incoming: status
                    ) {
                        self.resourceStatus = status
                    }
                } catch {
                    // keep last known
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func startHomeRunsPolling() {
        homeRunsPollTask?.cancel()
        homeRunsPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if case .home = self.context {
                    let projectIDs = self.projects.map(\.id)
                    if self.shouldUseCodexRPC {
                        for projectID in projectIDs {
                            if Task.isCancelled { break }
                            await self.projectService.refreshProjectSessionsFromCodex(projectID: projectID, failHard: false)
                            await self.projectService.refreshProjectRunsFromCodex(projectID: projectID, failHard: false)
                        }
                    } else if self.isGatewayConnected {
                        for projectID in projectIDs {
                            if Task.isCancelled { break }
                            await self.projectService.refreshProjectSessionsFromGateway(projectID: projectID, failHard: false)
                            await self.projectService.refreshProjectRunsFromGateway(projectID: projectID, failHard: false)
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    internal func gatewayHTTPBaseURL() -> URL? {
        guard let wsURL = URL(string: gatewayWSURLString) else { return nil }
        var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false)
        if components?.scheme == "wss" {
            components?.scheme = "https"
        } else if components?.scheme == "ws" {
            components?.scheme = "http"
        }
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    internal func codexWSURL() -> URL? {
        let normalized = Self.normalizedGatewayWSURLString(gatewayWSURLString) ?? gatewayWSURLString
        guard let wsURL = URL(string: normalized) else { return nil }
        guard var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/codex"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func connectCodex() async {
        guard isGatewayConfigured else { return }
        guard let wsURL = codexWSURL() else {
            codexConnectionState = .failed(message: "Invalid Codex URL")
            return
        }

        codexNotificationsTask?.cancel()
        codexNotificationsTask = nil
        codexServerRequestsTask?.cancel()
        codexServerRequestsTask = nil

        let client = CodexRPCClient(wsURL: wsURL, token: gatewayToken)
        codexClient = client
        await client.connect()
        codexConnectionState = client.connectionState
        guard isCodexConnected else { return }

        startCodexEventLoops()
    }

    private func startCodexEventLoops() {
        guard let codexClient else { return }

        codexNotificationsTask?.cancel()
        codexNotificationsTask = Task { [weak self] in
            guard let self else { return }
            for await notification in codexClient.notifications {
                self.handleCodexNotification(notification)
            }
        }

        codexServerRequestsTask?.cancel()
        codexServerRequestsTask = Task { [weak self] in
            guard let self else { return }
            for await request in codexClient.serverRequests {
                await self.handleCodexServerRequest(request)
            }
        }
    }

    internal func requestCodex<Params: Encodable>(method: String, params: Params) async throws -> CodexRPCResponse {
        if let override = codexRequestOverrideForTests {
            let data = try gatewayJSONEncoder.encode(params)
            let paramsValue = try gatewayJSONDecoder.decode(JSONValue.self, from: data)
            return try await override(method, paramsValue)
        }
        guard let codexClient, isCodexConnected else {
            throw NSError(domain: "LabOS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Codex client is not connected"])
        }
        return try await codexClient.request(method: method, params: params)
    }

    internal func decodeCodexResult<T: Decodable>(_ result: JSONValue?, key: String? = nil) throws -> T {
        let value: JSONValue
        if let key {
            guard let object = result?.objectValue, let nested = object[key] else {
                throw NSError(domain: "LabOS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing codex result key \(key)"])
            }
            value = nested
        } else {
            guard let result else {
                throw NSError(domain: "LabOS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing codex result payload"])
            }
            value = result
        }
        let data = try gatewayJSONEncoder.encode(value)
        return try gatewayJSONDecoder.decode(T.self, from: data)
    }

    private struct CodexSkillsListResponseWrapper: Codable {
        var skills: [CodexSkillsListEntry]?
        var entries: [CodexSkillsListEntry]?
        var data: [CodexSkillsListEntry]?
    }

    private func decodeCodexSkillsEntries(_ result: JSONValue?) throws -> [CodexSkillsListEntry] {
        // Known object wrappers:
        // - { "skills": [SkillsListEntry] } (legacy)
        // - { "entries": [SkillsListEntry] } (LabOS compatibility)
        // - { "data": [SkillsListEntry] } (codex-spec v2)
        if let object = result?.objectValue {
            if object["skills"] != nil {
                return try decodeCodexResult(result, key: "skills")
            }
            if object["entries"] != nil {
                return try decodeCodexResult(result, key: "entries")
            }
            if object["data"] != nil {
                return try decodeCodexResult(result, key: "data")
            }
        }

        // Some implementations may return wrapper variants directly.
        if let wrapper: CodexSkillsListResponseWrapper = try? decodeCodexResult(result) {
            if let skills = wrapper.skills { return skills }
            if let entries = wrapper.entries { return entries }
            if let data = wrapper.data { return data }
        }

        // Or the array itself.
        return try decodeCodexResult(result)
    }

    private func normalizeCodexSkillsErrorMessage(_ error: Error) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Failed to load skills." }

        let lower = raw.lowercased()
        let isMethodNotFound = (lower.contains("method not found") || lower.contains("unknown method")) && lower.contains("skills/list")
        if isMethodNotFound {
            return "This Hub build does not support skills yet. Update Hub/Codex and retry."
        }

        return raw
    }

    private func handleCodexNotification(_ notification: CodexRPCNotification) {
        guard let params = notification.params?.objectValue else { return }
        let threadId = normalizedOptionalString(params["threadId"]?.stringValue ?? "")
        let sessionID = self.resolveCodexSessionID(notificationParams: params, threadId: threadId)
        let notificationTurnID: String? = {
            switch notification.method {
            case "turn/started", "turn/completed":
                if let turn = params["turn"]?.objectValue,
                   let rawTurnID = turn["id"]?.stringValue {
                    return normalizedOptionalString(rawTurnID)
                }
                return nil
            default:
                if let rawTurnID = params["turnId"]?.stringValue {
                    return normalizedOptionalString(rawTurnID)
                }
                return nil
            }
        }()

        if notification.method != "turn/completed",
           let sessionID,
           let notificationTurnID,
           isCodexTurnSuppressed(sessionID: sessionID, turnID: notificationTurnID) {
            return
        }

        switch notification.method {
        case "turn/started":
            if let sessionID {
                streamingSessions.insert(sessionID)
                codexPendingThreadBindingSessions.remove(sessionID)
                if let turn = params["turn"]?.objectValue {
                    if let status = turn["status"]?.stringValue {
                        codexStatusTextBySession[sessionID] = status
                    }
                    if let rawTurnID = turn["id"]?.stringValue,
                       let turnId = normalizedOptionalString(rawTurnID),
                       !turnId.isEmpty {
                        codexActiveTurnIDBySession[sessionID] = turnId
                        if let threadId, !threadId.isEmpty {
                            let scopedTurnKey = "\(threadId)|\(turnId)"
                            let startedAt = Date()
                            codexTurnStartedAtByScopedBackendTurn[scopedTurnKey] = startedAt
                            codexPendingDurationMsByScopedBackendTurn[scopedTurnKey] = nil
                            if let userMessageID = codexFirstUserMessageIDByScopedBackendTurn[scopedTurnKey] {
                                var startedAtByTurnID = codexTrajectoryStartedAtBySession[sessionID] ?? [:]
                                startedAtByTurnID[userMessageID] = startedAt
                                codexTrajectoryStartedAtBySession[sessionID] = startedAtByTurnID
                            }
                        }
                    }
                }
                codexTurnDiffBySession[sessionID] = nil
            }
        case "turn/completed":
            if let sessionID {
                let turnId = params["turn"]?.objectValue?["id"]?.stringValue.flatMap(normalizedOptionalString)
                var scopedTurnKey: String?
                var scopedTurnStartedAt: Date?
                if let threadId, !threadId.isEmpty, let turnId, !turnId.isEmpty {
                    let key = "\(threadId)|\(turnId)"
                    scopedTurnKey = key
                    scopedTurnStartedAt = codexTurnStartedAtByScopedBackendTurn[key]
                }
                if let turn = params["turn"]?.objectValue,
                   let status = turn["status"]?.stringValue {
                    codexStatusTextBySession[sessionID] = status

                    let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if normalizedStatus == "interrupted"
                        || normalizedStatus == "canceled"
                        || normalizedStatus == "cancelled",
                        let threadId,
                        let turnId,
                        let userMessageID = codexFirstUserMessageIDByScopedBackendTurn["\(threadId)|\(turnId)"] {
                        var interrupted = codexInterruptedTurnIDsBySession[sessionID] ?? Set()
                        interrupted.insert(userMessageID)
                        codexInterruptedTurnIDsBySession[sessionID] = interrupted
                    }
                }

                if let scopedTurnKey,
                   let scopedTurnStartedAt {
                    let durationMs = max(0, Int(Date().timeIntervalSince(scopedTurnStartedAt) * 1_000))
                    if let userMessageID = codexFirstUserMessageIDByScopedBackendTurn[scopedTurnKey] {
                        var startedAtByTurnID = codexTrajectoryStartedAtBySession[sessionID] ?? [:]
                        startedAtByTurnID[userMessageID] = scopedTurnStartedAt
                        codexTrajectoryStartedAtBySession[sessionID] = startedAtByTurnID
                    }
                    if durationMs > 0 {
                        if let userMessageID = codexFirstUserMessageIDByScopedBackendTurn[scopedTurnKey] {
                            setCodexTrajectoryDuration(sessionID: sessionID, turnID: userMessageID, durationMs: durationMs)
                        } else {
                            codexPendingDurationMsByScopedBackendTurn[scopedTurnKey] = durationMs
                        }
                    }
                }

                if let scopedTurnKey {
                    codexTurnStartedAtByScopedBackendTurn[scopedTurnKey] = nil
                    if let userMessageID = codexFirstUserMessageIDByScopedBackendTurn[scopedTurnKey],
                       let pendingDurationMs = codexPendingDurationMsByScopedBackendTurn[scopedTurnKey],
                       pendingDurationMs > 0 {
                        setCodexTrajectoryDuration(sessionID: sessionID, turnID: userMessageID, durationMs: pendingDurationMs)
                        codexPendingDurationMsByScopedBackendTurn[scopedTurnKey] = nil
                    }
                }

                codexActiveTurnIDBySession[sessionID] = nil
                if let livePlan = livePlanBySession[sessionID],
                   Self.codexPlanIsTerminal(livePlan) {
                    livePlanBySession[sessionID] = nil
                }
                codexTurnDiffBySession[sessionID] = nil
                streamingSessions.remove(sessionID)
                codexPendingThreadBindingSessions.remove(sessionID)

                if let session = sessionRecord(for: sessionID) {
                    Task { @MainActor [weak self] in
                        self?.chatService.drainCodexQueueIfPossible(projectID: session.projectID, sessionID: sessionID)
                    }
                }

                if let turnId {
                    unsuppressCodexTurn(sessionID: sessionID, turnID: turnId)
                }
            }
        case "turn/plan/updated":
            applyCodexTurnPlanUpdated(notificationParams: params, sessionID: sessionID)
        case "turn/diff/updated":
            guard let sessionID,
                  let threadId,
                  let rawTurnId = params["turnId"]?.stringValue,
                  let turnId = normalizedOptionalString(rawTurnId)
            else { break }
            let diff = params["diff"]?.stringValue ?? ""
            if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                codexTurnDiffBySession[sessionID] = nil
                break
            }
            codexTurnDiffBySession[sessionID] = CodexTurnDiffState(
                sessionID: sessionID,
                threadId: threadId,
                turnId: turnId,
                diff: diff,
                updatedAt: .now
            )
        case "item/started":
            applyCodexItem(notificationParams: params, sessionID: sessionID)
        case "item/completed":
            applyCodexItem(notificationParams: params, sessionID: sessionID)
        case "item/agentMessage/delta":
            applyCodexAgentMessageDelta(notificationParams: params, sessionID: sessionID)
        case "item/commandExecution/outputDelta":
            applyCodexCommandOutputDelta(notificationParams: params, sessionID: sessionID)
        case "thread/tokenUsage/updated":
            applyCodexTokenUsage(notificationParams: params, sessionID: sessionID)
        case "codex/event/background_event":
            if let sessionID,
               let details = params["event"]?.objectValue,
               let text = details["message"]?.stringValue ?? details["event"]?.stringValue {
                codexStatusTextBySession[sessionID] = text
            }
        case "codex/event/error":
            if let sessionID,
               let error = params["error"]?.objectValue,
               let message = error["message"]?.stringValue {
                codexStatusTextBySession[sessionID] = "error: \(message)"
            }
        case "codex/event/view_image_tool_call", "codex/event/view_image/tool_call":
            if let sessionID,
               let rawPath = codexViewImagePath(from: params) {
                stageCodexImageForDisplay(sessionID: sessionID, rawPath: rawPath)
            }
        default:
            if let sessionID, notification.method.hasPrefix("codex/event/"),
               notification.method.contains("view_image"),
               let rawPath = codexViewImagePath(from: params) {
                stageCodexImageForDisplay(sessionID: sessionID, rawPath: rawPath)
                break
            }
            if let sessionID, notification.method.hasPrefix("codex/event/"),
               let statusText = extractCodexStatusText(notificationMethod: notification.method, params: params) {
                codexStatusTextBySession[sessionID] = statusText
            }
            break
        }
    }

    private func codexViewImagePath(from params: [String: JSONValue]) -> String? {
        if let rawPath = params["path"]?.stringValue,
           let normalized = normalizedOptionalString(rawPath) {
            return normalized
        }
        if let event = params["event"]?.objectValue,
           let rawPath = event["path"]?.stringValue,
           let normalized = normalizedOptionalString(rawPath) {
            return normalized
        }
        if let nested = codexFirstStringValue(forKey: "path", in: .object(params), maxDepth: 6),
           let normalized = normalizedOptionalString(nested) {
            return normalized
        }
        return nil
    }

    private func codexFirstStringValue(
        forKey key: String,
        in root: JSONValue,
        maxDepth: Int
    ) -> String? {
        guard maxDepth >= 0 else { return nil }
        var queue: [(JSONValue, Int)] = [(root, 0)]

        while !queue.isEmpty {
            let (value, depth) = queue.removeFirst()
            if depth > maxDepth { continue }

            switch value {
            case let .object(object):
                if let direct = object[key]?.stringValue {
                    return direct
                }
                guard depth < maxDepth else { continue }
                for child in object.values {
                    queue.append((child, depth + 1))
                }
            case let .array(array):
                guard depth < maxDepth else { continue }
                for child in array {
                    queue.append((child, depth + 1))
                }
            default:
                continue
            }
        }

        return nil
    }

    private func resolveCodexSessionID(notificationParams params: [String: JSONValue], threadId: String?) -> UUID? {
        if let threadId, let mapped = codexSessionByThread[threadId] {
            return mapped
        }

        if let threadId, let bound = bindUnknownCodexThreadIfPossible(threadId: threadId) {
            return bound
        }

        if let rawSessionId = params["sessionId"]?.stringValue,
           let parsedSessionId = UUID(uuidString: rawSessionId) {
            if let threadId {
                mapCodexThread(threadId, to: parsedSessionId)
            }
            return parsedSessionId
        }

        return nil
    }

    private func bindUnknownCodexThreadIfPossible(threadId: String) -> UUID? {
        if let mapped = codexSessionByThread[threadId] {
            return mapped
        }

        if codexPendingThreadBindingSessions.count == 1,
           let sessionId = codexPendingThreadBindingSessions.first {
            mapCodexThread(threadId, to: sessionId)
            return sessionId
        }

        return nil
    }

    private func mapCodexThread(_ threadId: String, to sessionID: UUID) {
        let normalized = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if let previous = codexThreadBySession[sessionID],
           previous != normalized {
            codexSessionByThread[previous] = nil
        }

        codexThreadBySession[sessionID] = normalized
        codexSessionByThread[normalized] = sessionID
        codexPendingThreadBindingSessions.remove(sessionID)
    }

    private func extractCodexStatusText(
        notificationMethod: String,
        params: [String: JSONValue]
    ) -> String? {
        if let direct = params["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !direct.isEmpty {
            return direct
        }

        if let event = params["event"]?.objectValue {
            let candidates: [String?] = [
                event["message"]?.stringValue,
                event["status"]?.stringValue,
                event["event"]?.stringValue,
                event["phase"]?.stringValue,
                event["type"]?.stringValue,
            ]
            for candidate in candidates {
                let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        if let suffix = notificationMethod.split(separator: "/").last {
            let raw = String(suffix).trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        }
        return nil
    }

    private func applyCodexItem(notificationParams params: [String: JSONValue], sessionID: UUID?) {
        guard let sessionID else { return }
        guard let itemValue = params["item"] else { return }
        let threadId = normalizedOptionalString(params["threadId"]?.stringValue ?? "")
        let turnId = normalizedOptionalString(params["turnId"]?.stringValue ?? "")
        guard let itemData = try? gatewayJSONEncoder.encode(itemValue),
              let item = try? gatewayJSONDecoder.decode(CodexThreadItem.self, from: itemData)
        else { return }

        if case let .commandExecution(command) = item {
            trackCodexNoResultCommand(sessionID: sessionID, command: command, now: .now)
        }

        let existing = codexItemsBySession[sessionID] ?? []
        if let threadId,
           let turnId,
           case let .userMessage(incomingUser) = item {
            let key = "\(threadId)|\(turnId)"
            if codexFirstUserMessageIDByScopedBackendTurn[key] == nil {
                codexFirstUserMessageIDByScopedBackendTurn[key] = incomingUser.id
            }
            if let startedAt = codexTurnStartedAtByScopedBackendTurn[key] {
                var startedAtByTurnID = codexTrajectoryStartedAtBySession[sessionID] ?? [:]
                startedAtByTurnID[incomingUser.id] = startedAt
                codexTrajectoryStartedAtBySession[sessionID] = startedAtByTurnID
            }
            if let pendingDurationMs = codexPendingDurationMsByScopedBackendTurn[key], pendingDurationMs > 0 {
                setCodexTrajectoryDuration(sessionID: sessionID, turnID: incomingUser.id, durationMs: pendingDurationMs)
                codexPendingDurationMsByScopedBackendTurn[key] = nil
            }
        }
        if case let .userMessage(incomingUser) = item,
           let localEchoID = Self.matchingLocalEchoUserItemID(for: incomingUser, in: existing) {
            migrateCodexTrajectoryStartedAtIfNeeded(sessionID: sessionID, fromTurnID: localEchoID, toTurnID: incomingUser.id)
            migrateCodexTrajectoryDurationIfNeeded(sessionID: sessionID, fromTurnID: localEchoID, toTurnID: incomingUser.id)
        }
        codexItemsBySession[sessionID] = Self.upsertCodexItemPreservingLocalEchoes(
            items: existing,
            incoming: item
        )
        if case let .imageView(imageItem) = item {
            stageCodexImageForDisplay(sessionID: sessionID, rawPath: imageItem.path)
        }
    }

    private static func matchingLocalEchoUserItemID(
        for incomingUser: CodexUserMessageItem,
        in items: [CodexThreadItem]
    ) -> String? {
        let incomingSignature = codexUserContentSignature(incomingUser.content)
        guard !incomingSignature.isEmpty else { return nil }
        for item in items {
            guard case let .userMessage(localUser) = item else { continue }
            guard localUser.id.hasPrefix(codexLocalUserItemPrefix) else { continue }
            if codexUserContentSignature(localUser.content) == incomingSignature {
                return localUser.id
            }
        }
        return nil
    }

    private func migrateCodexTrajectoryDurationIfNeeded(sessionID: UUID, fromTurnID: String, toTurnID: String) {
        let fromKey = fromTurnID.trimmingCharacters(in: .whitespacesAndNewlines)
        let toKey = toTurnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fromKey.isEmpty, !toKey.isEmpty, fromKey != toKey else { return }
        guard let durationMs = codexTrajectoryDuration(sessionID: sessionID, turnID: fromKey),
              durationMs > 0
        else { return }

        setCodexTrajectoryDuration(sessionID: sessionID, turnID: toKey, durationMs: durationMs)

        guard var turnDurations = codexTrajectoryDurationsBySession[sessionID] else { return }
        turnDurations[fromKey] = nil
        codexTrajectoryDurationsBySession[sessionID] = turnDurations.isEmpty ? nil : turnDurations
        persistCodexTrajectoryDurations()
    }

    private func migrateCodexTrajectoryStartedAtIfNeeded(sessionID: UUID, fromTurnID: String, toTurnID: String) {
        let fromKey = fromTurnID.trimmingCharacters(in: .whitespacesAndNewlines)
        let toKey = toTurnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fromKey.isEmpty, !toKey.isEmpty, fromKey != toKey else { return }
        guard var startedAtByTurnID = codexTrajectoryStartedAtBySession[sessionID],
              let startedAt = startedAtByTurnID[fromKey]
        else { return }

        if let existing = startedAtByTurnID[toKey] {
            startedAtByTurnID[toKey] = min(existing, startedAt)
        } else {
            startedAtByTurnID[toKey] = startedAt
        }
        startedAtByTurnID[fromKey] = nil
        codexTrajectoryStartedAtBySession[sessionID] = startedAtByTurnID.isEmpty ? nil : startedAtByTurnID
    }

    internal static func upsertCodexItemPreservingLocalEchoes(
        items: [CodexThreadItem],
        incoming: CodexThreadItem
    ) -> [CodexThreadItem] {
        var next = items

        if case let .userMessage(incomingUser) = incoming {
            let incomingSignature = codexUserContentSignature(incomingUser.content)
            if !incomingSignature.isEmpty,
               let localEchoIndex = next.firstIndex(where: { item in
                   guard case let .userMessage(localUser) = item else { return false }
                   guard localUser.id.hasPrefix(codexLocalUserItemPrefix) else { return false }
                   return codexUserContentSignature(localUser.content) == incomingSignature
               }) {
                next.remove(at: localEchoIndex)
            }
        }

        if let existingIndex = next.firstIndex(where: { $0.id == incoming.id }) {
            next[existingIndex] = incoming
        } else {
            next.append(incoming)
        }
        return next
    }

    public static func codexUserContentSignature(_ content: [CodexUserInput]) -> String {
        let signature = content
            .map { input in
                let type = input.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let text = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let url = input.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let rawPath = input.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let path: String
                switch type {
                case "localimage", "mention":
                    // Local echoes stage images on-device; Hub stages the same payload under
                    // a different path/name. Normalize so we can dedupe the optimistic echo.
                    path = codexNormalizedStagedFileName(rawPath)
                default:
                    path = rawPath
                }

                return [type, text, url, path].joined(separator: "|")
            }
            .joined(separator: "||")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return signature
    }

    private static func codexNormalizedStagedFileName(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let noScheme = trimmed.hasPrefix("file://") ? String(trimmed.dropFirst("file://".count)) : trimmed
        let fileName = URL(fileURLWithPath: noScheme).lastPathComponent
        guard !fileName.isEmpty else { return "" }

        let strippedPrefix = codexStripLeadingUUIDPrefix(fileName)
        let strippedSuffix = codexStripTrailingUUIDSuffix(strippedPrefix)
        return strippedSuffix.isEmpty ? fileName : strippedSuffix
    }

    private static func codexStripLeadingUUIDPrefix(_ fileName: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let stripped = codexStripLeadingUUIDPrefix(trimmed, uuidLength: 36) {
            return stripped
        }
        if let stripped = codexStripLeadingUUIDPrefix(trimmed, uuidLength: 32) {
            return stripped
        }

        return trimmed
    }

    private static func codexStripLeadingUUIDPrefix(_ fileName: String, uuidLength: Int) -> String? {
        guard fileName.count > uuidLength + 1 else { return nil }
        let dashIndex = fileName.index(fileName.startIndex, offsetBy: uuidLength)
        guard fileName[dashIndex] == "-" else { return nil }

        let uuid = String(fileName[..<dashIndex])
        guard codexIsUUIDLike(uuid) else { return nil }
        let afterDash = fileName.index(after: dashIndex)
        return String(fileName[afterDash...])
    }

    private static func codexStripTrailingUUIDSuffix(_ fileName: String) -> String {
        let ext = URL(fileURLWithPath: fileName).pathExtension
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return fileName }

        if let strippedStem = codexStripTrailingUUIDSuffix(stem, uuidLength: 36) {
            return ext.isEmpty ? strippedStem : "\(strippedStem).\(ext)"
        }
        if let strippedStem = codexStripTrailingUUIDSuffix(stem, uuidLength: 32) {
            return ext.isEmpty ? strippedStem : "\(strippedStem).\(ext)"
        }

        return fileName
    }

    private static func codexStripTrailingUUIDSuffix(_ stem: String, uuidLength: Int) -> String? {
        guard stem.count > uuidLength + 1 else { return nil }
        let dashIndex = stem.index(stem.endIndex, offsetBy: -(uuidLength + 1))
        guard stem[dashIndex] == "-" else { return nil }

        let uuidStart = stem.index(after: dashIndex)
        let uuid = String(stem[uuidStart...])
        guard codexIsUUIDLike(uuid) else { return nil }
        return String(stem[..<dashIndex])
    }

    private static func codexIsUUIDLike(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.count == 36 {
            let chars = Array(value)
            let hyphenOffsets: Set<Int> = [8, 13, 18, 23]
            for idx in 0..<chars.count {
                let ch = chars[idx]
                if hyphenOffsets.contains(idx) {
                    if ch != "-" { return false }
                    continue
                }
                guard ("0"..."9").contains(ch) || ("a"..."f").contains(ch) else { return false }
            }
            return true
        }
        if value.count == 32 {
            for ch in value {
                guard ("0"..."9").contains(ch) || ("a"..."f").contains(ch) else { return false }
            }
            return true
        }
        return false
    }

    private static func decodeCodexPromptQuestions(from params: [String: JSONValue]) -> [CodexPromptQuestion] {
        guard let questions = params["questions"]?.arrayValue else { return [] }
        return questions.compactMap { value -> CodexPromptQuestion? in
            guard let questionObject = value.objectValue else { return nil }
            let questionID = codexPromptString(questionObject["id"]) ?? "response"
            let questionHeader = codexPromptString(questionObject["header"])
            let questionPrompt = codexPromptString(questionObject["question"])
                ?? codexPromptString(questionObject["prompt"])
                ?? ""
            let questionIsOther = questionObject["isOther"]?.boolValue ?? false

            let options: [CodexPromptOption] = {
                guard let rawOptions = questionObject["options"]?.arrayValue else { return [] }
                return rawOptions.compactMap { optionValue -> CodexPromptOption? in
                    guard let optionObject = optionValue.objectValue else { return nil }
                    guard let label = codexPromptString(optionObject["label"]), !label.isEmpty else { return nil }
                    let optionID = codexPromptString(optionObject["id"]) ?? label
                    let description = codexPromptString(optionObject["description"])
                    let isOther = optionObject["isOther"]?.boolValue ?? false
                    return CodexPromptOption(
                        id: optionID,
                        label: label,
                        description: description,
                        isOther: isOther
                    )
                }
            }()

            return CodexPromptQuestion(
                id: questionID,
                header: questionHeader,
                prompt: questionPrompt,
                isOther: questionIsOther,
                options: options
            )
        }
    }

    private static func codexPromptKind(from params: [String: JSONValue]) -> String {
        guard let firstQuestion = params["questions"]?.arrayValue?.first?.objectValue,
              let questionID = codexPromptString(firstQuestion["id"])?.lowercased()
        else {
            return "prompt"
        }
        if questionID == "labos_plan_implementation_decision" {
            return "implement_confirmation"
        }
        return "prompt"
    }

    private static func codexPromptString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let raw: String
        switch value {
        case let .string(text):
            raw = text
        case let .number(number):
            raw = String(number)
        case let .bool(flag):
            raw = flag ? "true" : "false"
        default:
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func codexPromptDraftDefaultsKey(sessionID: UUID, requestID: CodexRequestID) -> String {
        "\(DefaultsKey.codexPromptDraftPrefix).\(sessionID.uuidString.lowercased()).\(codexRequestIDStorageKey(requestID))"
    }

    private func codexRequestIDStorageKey(_ requestID: CodexRequestID) -> String {
        let raw: String
        switch requestID {
        case let .string(value):
            raw = value
        case let .int(value):
            raw = String(value)
        }
        let sanitized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return sanitized.isEmpty ? "unknown" : sanitized
    }

    private func codexQueuedInputsDefaultsKey(sessionID: UUID) -> String {
        "\(DefaultsKey.codexQueuedInputPrefix).\(sessionID.uuidString.lowercased())"
    }

    internal func ensureCodexQueuedInputsLoaded(sessionID: UUID) {
        guard !codexQueuedInputsLoadedSessions.contains(sessionID) else { return }
        codexQueuedInputsLoadedSessions.insert(sessionID)

        let key = codexQueuedInputsDefaultsKey(sessionID: sessionID)
        guard let data = defaults.data(forKey: key),
              let decoded = try? gatewayJSONDecoder.decode([CodexQueuedUserInputItem].self, from: data)
        else {
            codexQueuedInputsBySession[sessionID] = codexQueuedInputsBySession[sessionID] ?? []
            return
        }

        var filtered: [CodexQueuedUserInputItem] = []
        filtered.reserveCapacity(decoded.count)
        for raw in decoded {
            var item = raw
            if item.status == .sending {
                item.status = .queued
                item.error = nil
            }
            item.attachments = item.attachments.filter { attachment in
                FileManager.default.fileExists(atPath: attachment.storedPath)
            }
            filtered.append(item)
        }

        codexQueuedInputsBySession[sessionID] = normalizeCodexQueuedInputs(filtered)
    }

    internal func persistCodexQueuedInputs(sessionID: UUID) {
        let key = codexQueuedInputsDefaultsKey(sessionID: sessionID)
        let items = codexQueuedInputsBySession[sessionID] ?? []
        guard !items.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? gatewayJSONEncoder.encode(items) {
            defaults.set(data, forKey: key)
        }
    }

    internal func clearPersistedCodexQueuedInputs(sessionID: UUID) {
        let key = codexQueuedInputsDefaultsKey(sessionID: sessionID)
        defaults.removeObject(forKey: key)
    }

    private func normalizeCodexQueuedInputs(_ items: [CodexQueuedUserInputItem]) -> [CodexQueuedUserInputItem] {
        let sorted = items.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex {
                return lhs.sortIndex < rhs.sortIndex
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return sorted.enumerated().map { index, item in
            var updated = item
            updated.sortIndex = index
            return updated
        }
    }

    private static func moveArray<T>(_ array: inout [T], from offsets: IndexSet, to destination: Int) {
        let sorted = offsets.sorted()
        guard !sorted.isEmpty else { return }

        var dest = destination
        for index in sorted where index < dest {
            dest -= 1
        }

        let moving = sorted.compactMap { index -> T? in
            guard array.indices.contains(index) else { return nil }
            return array[index]
        }

        for index in sorted.sorted(by: >) {
            guard array.indices.contains(index) else { continue }
            array.remove(at: index)
        }

        dest = min(max(dest, 0), array.count)
        array.insert(contentsOf: moving, at: dest)
    }

    private func applyCodexAgentMessageDelta(notificationParams params: [String: JSONValue], sessionID: UUID?) {
        guard let sessionID else { return }
        guard let itemId = params["itemId"]?.stringValue else { return }
        let delta = params["delta"]?.stringValue ?? ""
        guard !delta.isEmpty else { return }

        var items = codexItemsBySession[sessionID] ?? []
        if let index = items.firstIndex(where: { $0.id == itemId }) {
            if case let .agentMessage(existing) = items[index] {
                let merged = CodexAgentMessageItem(type: existing.type, id: existing.id, text: existing.text + delta)
                items[index] = .agentMessage(merged)
                codexItemsBySession[sessionID] = items
                return
            }
        }

        let fallback = CodexAgentMessageItem(type: "agentMessage", id: itemId, text: delta)
        items.append(.agentMessage(fallback))
        codexItemsBySession[sessionID] = items
    }

    private func applyCodexCommandOutputDelta(notificationParams params: [String: JSONValue], sessionID: UUID?) {
        guard let sessionID else { return }
        guard let itemId = params["itemId"]?.stringValue else { return }
        let delta = params["delta"]?.stringValue ?? ""
        guard !delta.isEmpty else { return }
        removeCodexNoResultCommandTracking(sessionID: sessionID, itemID: itemId)

        var items = codexItemsBySession[sessionID] ?? []
        guard let index = items.firstIndex(where: { $0.id == itemId }) else { return }
        guard case let .commandExecution(command) = items[index] else { return }

        let merged = CodexCommandExecutionItem(
            type: command.type,
            id: command.id,
            command: command.command,
            cwd: command.cwd,
            processId: command.processId,
            status: command.status,
            aggregatedOutput: (command.aggregatedOutput ?? "") + delta,
            exitCode: command.exitCode,
            durationMs: command.durationMs,
            commandActions: command.commandActions
        )
        items[index] = .commandExecution(merged)
        codexItemsBySession[sessionID] = items
    }

    private static func isInProgressCommandStatus(_ rawStatus: String) -> Bool {
        let normalized = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "inprogress" || normalized == "in_progress"
    }

    private static func commandHasNoResult(_ command: CodexCommandExecutionItem) -> Bool {
        let output = command.aggregatedOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty
    }

    private func trackCodexNoResultCommand(
        sessionID: UUID,
        command: CodexCommandExecutionItem,
        now: Date
    ) {
        guard Self.isInProgressCommandStatus(command.status), Self.commandHasNoResult(command) else {
            removeCodexNoResultCommandTracking(sessionID: sessionID, itemID: command.id)
            return
        }

        var startedAtByCommandID = codexCommandNoResultStartedAtBySession[sessionID] ?? [:]
        if startedAtByCommandID[command.id] == nil {
            startedAtByCommandID[command.id] = now
        }
        codexCommandNoResultStartedAtBySession[sessionID] = startedAtByCommandID
    }

    private func removeCodexNoResultCommandTracking(sessionID: UUID, itemID: String) {
        guard var startedAtByCommandID = codexCommandNoResultStartedAtBySession[sessionID] else { return }
        startedAtByCommandID[itemID] = nil
        codexCommandNoResultStartedAtBySession[sessionID] = startedAtByCommandID.isEmpty ? nil : startedAtByCommandID
    }

    private func applyCodexTokenUsage(notificationParams params: [String: JSONValue], sessionID: UUID?) {
        guard let sessionID else { return }
        guard let threadId = params["threadId"]?.stringValue else { return }
        guard let tokenUsage = params["tokenUsage"]?.objectValue else { return }

        let lastUsage = tokenUsage["last"]?.objectValue ?? [:]
        let totalUsage = tokenUsage["total"]?.objectValue ?? [:]

        let contextWindow = Self.codexTokenCount(
            tokenUsage["modelContextWindow"],
            tokenUsage["contextWindow"],
            tokenUsage["contextWindowTokens"]
        )
        let inputTokens = Self.codexTokenCount(
            lastUsage["inputTokens"],
            tokenUsage["inputTokens"],
            tokenUsage["totalInputTokens"],
            totalUsage["inputTokens"]
        )
        let outputTokens = Self.codexTokenCount(
            lastUsage["outputTokens"],
            tokenUsage["outputTokens"],
            tokenUsage["totalOutputTokens"],
            totalUsage["outputTokens"]
        )
        let totalTokens = Self.codexTokenCount(
            lastUsage["totalTokens"],
            tokenUsage["totalTokens"],
            totalUsage["totalTokens"],
            tokenUsage["totalInputTokens"],
            tokenUsage["inputTokens"]
        )
        let remaining: Int? = {
            guard let contextWindow, let inputTokens else { return nil }
            return max(0, contextWindow - inputTokens)
        }()

        let usage = CodexTokenUsage(
            threadId: threadId,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            contextWindowTokens: contextWindow,
            remainingTokens: remaining,
            model: tokenUsage["model"]?.stringValue
                ?? tokenUsage["modelId"]?.stringValue
                ?? lastUsage["model"]?.stringValue
                ?? totalUsage["model"]?.stringValue
        )
        codexTokenUsageBySession[sessionID] = usage

        if let projectID = sessionProjectID(sessionID),
           let contextWindow,
           let inputTokens {
            sessionContextBySession[sessionID] = SessionContextState(
                projectId: projectID,
                sessionId: sessionID,
                modelId: usage.model,
                contextWindowTokens: contextWindow,
                usedInputTokens: inputTokens,
                usedTokens: totalTokens,
                remainingTokens: max(0, contextWindow - inputTokens),
                updatedAt: Date()
            )
        }
    }

    private static func codexTokenCount(_ values: JSONValue?...) -> Int? {
        for value in values {
            guard let raw = value?.intValue else { continue }
            return max(0, raw)
        }
        return nil
    }

    private func applyCodexTurnPlanUpdated(notificationParams params: [String: JSONValue], sessionID: UUID?) {
        guard let sessionID else { return }
        guard let projectID = sessionProjectID(sessionID) else { return }
        guard let planArray = params["plan"]?.arrayValue else { return }

        let planItems: [AgentPlanUpdatedPayload.PlanItem] = planArray.compactMap { entry in
            guard let object = entry.objectValue else { return nil }
            guard let rawStep = object["step"]?.stringValue,
                  let step = normalizedOptionalString(rawStep)
            else { return nil }

            let rawStatus = object["status"]?.stringValue ?? "pending"
            let normalizedStatus = Self.normalizeCodexPlanStatus(rawStatus)
            return AgentPlanUpdatedPayload.PlanItem(step: step, status: normalizedStatus)
        }

        let explanation: String? = {
            guard let raw = params["explanation"]?.stringValue else { return nil }
            return normalizedOptionalString(raw)
        }()

        livePlanBySession[sessionID] = AgentPlanUpdatedPayload(
            agentRunId: UUID(),
            projectId: projectID,
            sessionId: sessionID,
            explanation: explanation,
            plan: planItems
        )
    }

    private static func normalizeCodexPlanStatus(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "inprogress", "in_progress":
            return "in_progress"
        case "completed":
            return "completed"
        default:
            return "pending"
        }
    }

    internal static func codexPlanIsTerminal(_ plan: AgentPlanUpdatedPayload) -> Bool {
        !codexPlanHasIncompleteSteps(plan)
    }

    internal static func codexPlanHasIncompleteSteps(_ plan: AgentPlanUpdatedPayload) -> Bool {
        for item in plan.plan {
            let normalized = item.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized != "completed" {
                return true
            }
        }
        return false
    }

    private func sessionProjectID(_ sessionID: UUID) -> UUID? {
        for (projectID, sessions) in sessionsByProject where sessions.contains(where: { $0.id == sessionID }) {
            return projectID
        }
        return activeProjectID
    }

    private func publishPendingUserInputSignal(sessionID: UUID, requestID: CodexRequestID, promptText: String?) {
        guard let projectID = sessionProjectID(sessionID) else { return }
        let projectName = projects.first(where: { $0.id == projectID })?.name ?? "Project"
        let sessionTitle = sessionRecord(for: sessionID)?.title ?? "Session"

        latestPendingUserInputSignal = PendingUserInputSignal(
            projectID: projectID,
            sessionID: sessionID,
            requestID: requestID,
            projectName: projectName,
            sessionTitle: sessionTitle,
            promptText: promptText?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func updateSessionPendingUserInputMetadata(
        sessionID: UUID,
        hasPending: Bool?,
        count: Int?,
        kind: String?
    ) {
        for projectID in sessionsByProject.keys {
            guard var sessions = sessionsByProject[projectID],
                  let index = sessions.firstIndex(where: { $0.id == sessionID })
            else { continue }

            sessions[index].hasPendingUserInput = hasPending
            sessions[index].pendingUserInputCount = count
            sessions[index].pendingUserInputKind = kind
            sessionsByProject[projectID] = sessions
            return
        }
    }

    private func enqueueCodexPendingPrompt(_ prompt: CodexPendingPrompt) {
        var queue = codexPendingPromptBySession[prompt.sessionID] ?? []
        queue.removeAll { $0.requestID == prompt.requestID }
        queue.append(prompt)
        codexPendingPromptBySession[prompt.sessionID] = queue
        refreshSessionPendingUserInputMetadata(sessionID: prompt.sessionID)
    }

    private func dequeueCodexPendingPrompt(sessionID: UUID, requestID: CodexRequestID) {
        guard var queue = codexPendingPromptBySession[sessionID] else { return }
        queue.removeAll { $0.requestID == requestID }
        codexPendingPromptBySession[sessionID] = queue.isEmpty ? nil : queue
        clearCodexPromptDraft(sessionID: sessionID, requestID: requestID)
        refreshSessionPendingUserInputMetadata(sessionID: sessionID)
    }

    private func clearCodexPendingPrompts(sessionID: UUID) {
        codexPendingPromptBySession[sessionID] = nil
        refreshSessionPendingUserInputMetadata(sessionID: sessionID)
    }

    func dismissImplementConfirmationPrompt(sessionID: UUID) {
        guard let queue = codexPendingPromptBySession[sessionID], !queue.isEmpty else { return }
        let removed = queue.filter { $0.kind == "implement_confirmation" }
        guard !removed.isEmpty else { return }

        let remaining = queue.filter { $0.kind != "implement_confirmation" }
        codexPendingPromptBySession[sessionID] = remaining.isEmpty ? nil : remaining
        for prompt in removed {
            clearCodexPromptDraft(sessionID: sessionID, requestID: prompt.requestID)
        }
        refreshSessionPendingUserInputMetadata(sessionID: sessionID)
    }

    private func pauseStreamingForUserInput(sessionID: UUID) {
        streamingSessions.remove(sessionID)
        codexPendingThreadBindingSessions.remove(sessionID)
        streamingAssistantMessageIDBySession[sessionID] = nil
    }

    private func hasActiveCodexTurn(sessionID: UUID) -> Bool {
        guard let rawTurnID = codexActiveTurnIDBySession[sessionID] else { return false }
        return normalizedOptionalString(rawTurnID) != nil
    }

    private func resumeStreamingForActiveTurnIfNeeded(sessionID: UUID) {
        guard hasActiveCodexTurn(sessionID: sessionID) else {
            pauseStreamingForUserInput(sessionID: sessionID)
            return
        }
        streamingSessions.insert(sessionID)
        codexStatusTextBySession[sessionID] = "in_progress"
    }

    private func shouldResumeStreamingAfterPromptResponse(
        sessionID: UUID,
        requestID: CodexRequestID,
        answers: [String: [String]]
    ) -> Bool {
        let queuedPrompt = codexPendingPromptBySession[sessionID]?.first(where: { $0.requestID == requestID })
        let isImplementConfirmation = queuedPrompt?.kind == "implement_confirmation"
            || answers.keys.contains(Self.planImplementationDecisionQuestionID)
        if isImplementConfirmation {
            guard let decision = firstNormalizedAnswer(
                for: Self.planImplementationDecisionQuestionID,
                in: answers
            )
            else {
                return false
            }
            guard Self.isPlanImplementationApprovalDecision(decision) else {
                return false
            }
            return hasActiveCodexTurn(sessionID: sessionID)
        }
        return hasActiveCodexTurn(sessionID: sessionID)
    }

    private func firstNormalizedAnswer(for questionID: String, in answers: [String: [String]]) -> String? {
        guard let answerList = answers[questionID] else { return nil }
        for answer in answerList {
            if let normalized = normalizedOptionalString(answer) {
                return normalized
            }
        }
        return nil
    }

    func refreshSessionPendingUserInputMetadata(sessionID: UUID) {
        let promptQueue = codexPendingPromptBySession[sessionID] ?? []
        let promptCount = promptQueue.count
        let approvalCount = codexPendingApprovalsBySession[sessionID]?.count ?? 0
        let planApprovalCount = planService.pendingApproval(for: sessionID) == nil ? 0 : 1
        let total = promptCount + approvalCount + planApprovalCount
        let kind: String? = {
            if let prompt = promptQueue.first {
                return prompt.kind
            }
            if approvalCount > 0 {
                return "approval"
            }
            if planApprovalCount > 0 {
                return "plan"
            }
            return nil
        }()
        updateSessionPendingUserInputMetadata(
            sessionID: sessionID,
            hasPending: total > 0,
            count: total,
            kind: kind
        )
    }

    private func applyE2EFixturesIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard env["LABOS_E2E_FIXTURE_PLAN_PROMPT_FLOW"] == "1" else { return }

        guard let projectID = UUID(uuidString: "11111111-1111-4111-8111-111111111111"),
              let sessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        else {
            return
        }

        let project = Project(
            id: projectID,
            name: "E2E Plan Prompt Project",
            backendEngine: "codex-app-server"
        )
        let session = Session(
            id: sessionID,
            projectID: projectID,
            title: "E2E Plan Prompt Session",
            backendEngine: "codex-app-server",
            codexThreadId: "thread_e2e_plan_prompt",
            hasPendingUserInput: true,
            pendingUserInputCount: 1,
            pendingUserInputKind: "prompt"
        )

        projects = [project]
        sessionsByProject = [projectID: [session]]
        artifactsByProject = [projectID: []]
        runsByProject = [projectID: []]
        messagesBySession = [sessionID: []]
        codexItemsBySession = [sessionID: []]
        codexPendingApprovalsBySession = [:]
        codexQueuedInputsBySession = [:]
        codexStatusTextBySession = [:]
        codexTokenUsageBySession = [:]
        codexFullAccessBySession = [sessionID: false]
        codexThreadBySession = [sessionID: "thread_e2e_plan_prompt"]
        codexSessionByThread = ["thread_e2e_plan_prompt": sessionID]
        codexPendingThreadBindingSessions = []
        livePlanBySession = [:]
        activeInlineProcessBySession = [:]
        persistedProcessSummaryByMessageID = [:]
        activeProjectID = projectID
        activeSessionID = nil
        planModeEnabledBySession[sessionID] = true
        selectedModelIdBySession[sessionID] = ""

        codexPendingPromptBySession[sessionID] = [
            CodexPendingPrompt(
                requestID: .string("req_e2e_plan_prompt"),
                sessionID: sessionID,
                threadId: "thread_e2e_plan_prompt",
                turnId: "turn_e2e_plan_prompt",
                prompt: "Choose how to execute this plan",
                questions: [
                    CodexPromptQuestion(
                        id: "execution_mode",
                        prompt: "Pick execution mode",
                        options: [
                            CodexPromptOption(
                                id: "proceed_now",
                                label: "Proceed now",
                                description: "Run immediately with full plan updates.",
                                isOther: false
                            ),
                            CodexPromptOption(
                                id: "review_first",
                                label: "Review first",
                                description: "Pause after showing initial progress.",
                                isOther: false
                            ),
                        ]
                    ),
                ],
                rawParams: nil
            ),
        ]
    }

    private func applyE2EPlanPromptFlowAfterResponseIfNeeded(sessionID: UUID) {
        let env = ProcessInfo.processInfo.environment
        guard env["LABOS_E2E_FIXTURE_PLAN_PROMPT_FLOW"] == "1" else { return }
        guard let fixtureSessionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222"),
              sessionID == fixtureSessionID
        else { return }
        guard let projectID = sessionProjectID(sessionID) else { return }

        livePlanBySession[sessionID] = AgentPlanUpdatedPayload(
            agentRunId: UUID(),
            projectId: projectID,
            sessionId: sessionID,
            explanation: "Executing approved plan",
            plan: [
                .init(step: "Capture constraints", status: "completed"),
                .init(step: "Execute approved plan", status: "in_progress"),
                .init(step: "Summarize result", status: "pending"),
            ]
        )
    }

    private func captureCodexProposedPlanTextIfNeeded(prompt: CodexPendingPrompt) {
        guard prompt.kind == "implement_confirmation" else { return }
        let threadId = prompt.threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadId.isEmpty,
              let turnId = normalizedOptionalString(prompt.turnId ?? "")
        else { return }

        let key = "\(threadId)|\(turnId)"
        guard let userTurnID = codexFirstUserMessageIDByScopedBackendTurn[key],
              let normalizedUserTurnID = normalizedOptionalString(userTurnID),
              let slice = codexTurnSliceItems(sessionID: prompt.sessionID, userMessageID: normalizedUserTurnID),
              let extracted = CodexProposedPlanExtractor.extract(
                  from: Array(slice),
                  allowHeuristicFallback: false
              )
        else { return }

        var byTurn = codexProposedPlanTextBySession[prompt.sessionID] ?? [:]
        byTurn[normalizedUserTurnID] = extracted
        codexProposedPlanTextBySession[prompt.sessionID] = byTurn
    }

    private func codexTurnSliceItems(sessionID: UUID, userMessageID: String) -> ArraySlice<CodexThreadItem>? {
        let items = codexItemsBySession[sessionID] ?? []
        guard !items.isEmpty else { return nil }
        guard let startIndex = items.firstIndex(where: { item in
            guard case let .userMessage(user) = item else { return false }
            return user.id == userMessageID
        }) else { return nil }

        let endIndex: Int = {
            let nextStart = startIndex + 1
            guard nextStart < items.count else { return items.count }
            return items[nextStart...].firstIndex(where: { item in
                guard case .userMessage = item else { return false }
                return true
            }) ?? items.count
        }()

        return items[startIndex..<endIndex]
    }

    private func handleCodexServerRequest(_ request: CodexRPCRequest) async {
        guard let params = request.params?.objectValue else {
            try? await codexClient?.respond(
                error: CodexRPCError(code: -32602, message: "Missing params"),
                for: request.id
            )
            return
        }

        let threadId = normalizedOptionalString(params["threadId"]?.stringValue ?? "") ?? ""
        guard let sessionID = self.resolveCodexSessionID(notificationParams: params, threadId: threadId) else {
            try? await codexClient?.respond(
                error: CodexRPCError(code: -32004, message: "Unknown thread"),
                for: request.id
            )
            return
        }

        switch request.method {
        case CodexApprovalKind.commandExecution.rawValue, CodexApprovalKind.fileChange.rawValue:
            let kind: CodexApprovalKind = request.method == CodexApprovalKind.commandExecution.rawValue ? .commandExecution : .fileChange
            let approval = CodexPendingApproval(
                requestID: request.id,
                kind: kind,
                sessionID: sessionID,
                threadId: threadId,
                turnId: params["turnId"]?.stringValue,
                itemId: params["itemId"]?.stringValue,
                reason: params["reason"]?.stringValue,
                command: params["command"]?.stringValue,
                cwd: params["cwd"]?.stringValue,
                grantRoot: params["grantRoot"]?.stringValue,
                rawParams: request.params
            )
            var approvals = codexPendingApprovalsBySession[sessionID] ?? []
            approvals.removeAll { $0.requestID == request.id }
            approvals.append(approval)
            codexPendingApprovalsBySession[sessionID] = approvals
            refreshSessionPendingUserInputMetadata(sessionID: sessionID)
        case "item/tool/requestUserInput":
            let questions = Self.decodeCodexPromptQuestions(from: params)
            let prompt = CodexPendingPrompt(
                requestID: request.id,
                sessionID: sessionID,
                threadId: threadId,
                turnId: params["turnId"]?.stringValue,
                kind: Self.codexPromptKind(from: params),
                prompt: params["prompt"]?.stringValue ?? params["message"]?.stringValue,
                questions: questions,
                rawParams: request.params
            )
            enqueueCodexPendingPrompt(prompt)
            publishPendingUserInputSignal(
                sessionID: sessionID,
                requestID: request.id,
                promptText: prompt.prompt
            )
            captureCodexProposedPlanTextIfNeeded(prompt: prompt)
            pauseStreamingForUserInput(sessionID: sessionID)
        case "item/tool/call":
            let toolName = normalizedOptionalString(params["tool"]?.stringValue ?? "")?.lowercased() ?? ""
            guard toolName == "update_plan" else {
                await respondToCodexServerRequest(
                    requestID: request.id,
                    result: codexDynamicToolCallResponse(
                        success: false,
                        message: "Unsupported dynamic tool call: \(toolName.isEmpty ? request.method : toolName)"
                    )
                )
                return
            }

            guard let update = decodeDynamicPlanUpdate(arguments: params["arguments"]) else {
                await respondToCodexServerRequest(
                    requestID: request.id,
                    result: codexDynamicToolCallResponse(success: false, message: "Missing or invalid update_plan arguments.")
                )
                return
            }
            guard let projectID = sessionProjectID(sessionID) else {
                await respondToCodexServerRequest(
                    requestID: request.id,
                    result: codexDynamicToolCallResponse(success: false, message: "Unable to resolve project for plan update.")
                )
                return
            }

            livePlanBySession[sessionID] = AgentPlanUpdatedPayload(
                agentRunId: UUID(),
                projectId: projectID,
                sessionId: sessionID,
                explanation: update.explanation,
                plan: update.plan
            )

            await respondToCodexServerRequest(
                requestID: request.id,
                result: codexDynamicToolCallResponse(success: true, message: "Plan updated.")
            )
        default:
            try? await codexClient?.respond(
                error: CodexRPCError(code: -32601, message: "Unsupported server request: \(request.method)"),
                for: request.id
            )
        }
    }

    private func respondToCodexServerRequest(
        requestID: CodexRequestID,
        result: JSONValue? = nil,
        error: CodexRPCError? = nil
    ) async {
        if let override = codexServerResponseOverrideForTests {
            override(requestID, result, error)
            return
        }
        guard let codexClient else { return }
        if let error {
            try? await codexClient.respond(error: error, for: requestID)
            return
        }
        try? await codexClient.respond(result: result, for: requestID)
    }

    private func codexDynamicToolCallResponse(success: Bool, message: String) -> JSONValue {
        .object([
            "success": .bool(success),
            "contentItems": .array([
                .object([
                    "type": .string("inputText"),
                    "text": .string(message),
                ]),
            ]),
        ])
    }

    private func decodeDynamicPlanUpdate(arguments: JSONValue?) -> (explanation: String?, plan: [AgentPlanUpdatedPayload.PlanItem])? {
        guard let object = arguments?.objectValue else { return nil }
        guard let planRaw = object["plan"]?.arrayValue else { return nil }

        let plan = planRaw.compactMap { entry -> AgentPlanUpdatedPayload.PlanItem? in
            guard let row = entry.objectValue else { return nil }
            guard let rawStep = row["step"]?.stringValue,
                  let step = normalizedOptionalString(rawStep),
                  !step.isEmpty
            else { return nil }
            let rawStatus = row["status"]?.stringValue ?? "pending"
            return AgentPlanUpdatedPayload.PlanItem(
                step: step,
                status: normalizePlanStatusFromDynamicTool(rawStatus)
            )
        }

        guard !plan.isEmpty else { return nil }
        let explanation = normalizedOptionalString(object["explanation"]?.stringValue ?? "")
        return (explanation, plan)
    }

    private func normalizePlanStatusFromDynamicTool(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "completed":
            return "completed"
        case "in_progress", "inprogress":
            return "in_progress"
        default:
            return "pending"
        }
    }

    private func refreshProjectsFromGateway() async {
        await projectService.refreshProjectsFromGateway()
    }

    private func refreshProjectFromGateway(projectID: UUID) async {
        await projectService.refreshProjectFromGateway(projectID: projectID)
    }

    private func refreshProjectsFromCodex() async {
        await projectService.refreshProjectsFromCodex()
    }

    private func refreshProjectFromCodex(projectID: UUID) async {
        await projectService.refreshProjectFromCodex(projectID: projectID)
    }

    func applySessionHistorySnapshot(
        projectID: UUID,
        sessionID: UUID,
        messages: [ChatMessage],
        fetchedAt: Date
    ) {
        chatService.applySessionHistorySnapshot(projectID: projectID, sessionID: sessionID, messages: messages, fetchedAt: fetchedAt)
    }

    static func latestAssistantReplyID(in messages: [ChatMessage]) -> UUID? {
        guard !messages.isEmpty else { return nil }
        let sorted = messages.sorted(by: Self.messageDisplayOrder)
        let latestUserIndex = sorted.lastIndex(where: { $0.role == .user })
        for index in sorted.indices.reversed() {
            guard sorted[index].role == .assistant else { continue }
            if let latestUserIndex, index <= latestUserIndex {
                continue
            }
            return sorted[index].id
        }
        return nil
    }

    internal func decodeGatewayPayload<T: Decodable>(_ payload: [String: JSONValue]?, key: String) throws -> T {
        guard let payload, let value = payload[key] else {
            throw NSError(domain: "LabOS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing payload key \(key)"])
        }
        let data = try gatewayJSONEncoder.encode(value)
        return try gatewayJSONDecoder.decode(T.self, from: data)
    }

    internal func decodeGatewayPayloadObject<T: Decodable>(_ payload: [String: JSONValue]?) throws -> T {
        guard let payload else {
            throw NSError(domain: "LabOS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing payload object"])
        }
        let data = try gatewayJSONEncoder.encode(JSONValue.object(payload))
        return try gatewayJSONDecoder.decode(T.self, from: data)
    }

    func _receiveCodexNotificationForTesting(_ notification: CodexRPCNotification) {
        handleCodexNotification(notification)
    }

    func _receiveCodexServerRequestForTesting(_ request: CodexRPCRequest) async {
        await handleCodexServerRequest(request)
    }

	    func _receiveGatewayEventForTesting(_ event: GatewayEvent) {
        handleGatewayEvent(event)
    }

	    func handleGatewayEvent(_ event: GatewayEvent) {
	        switch event {
	        case let .projectsUpdated(project, change):
            if change == "deleted" {
                removeProjectLocally(projectID: project.id)
            } else {
                upsertProject(project)
            }

	        case let .sessionsUpdated(session, change):
	            if change == "deleted" {
	                removeSessionLocally(projectID: session.projectID, sessionID: session.id)
	            } else {
	                upsertSession(session)
	            }

        case let .sessionPermissionUpdated(payload):
            composerService.handleSessionPermissionUpdated(payload)

        case let .chatMessageCreated(_, sessionID, message):
            chatService.applyRemoteMessage(sessionID: sessionID, message: message)

        case let .assistantDelta(payload):
            chatService.applyAssistantDelta(payload)

        case let .toolEvent(payload):
            chatService.applyToolEvent(payload)

	        case let .planUpdated(payload):
	            livePlanBySession[payload.sessionId] = payload

	        case let .sessionContextUpdated(payload):
	            sessionContextBySession[payload.sessionId] = SessionContextState(
	                projectId: payload.projectId,
	                sessionId: payload.sessionId,
	                modelId: payload.modelId,
	                contextWindowTokens: payload.contextWindowTokens,
	                usedInputTokens: payload.usedInputTokens,
	                usedTokens: payload.usedTokens,
	                remainingTokens: payload.remainingTokens,
	                updatedAt: payload.updatedAt
	            )

	        case let .approvalRequested(payload):
            planService.handleApprovalRequested(payload)
            refreshSessionPendingUserInputMetadata(sessionID: payload.sessionId)

        case let .approvalResolved(planID, decision):
            let mappedSessionID = planService.planSessionByPlanID[planID]
            planService.handleApprovalResolved(planID: planID, decision: decision)
            if let mappedSessionID {
                refreshSessionPendingUserInputMetadata(sessionID: mappedSessionID)
            }

        case let .runsUpdated(projectID, run, change: _):
            upsertRun(projectID: projectID, run: run)

        case let .runsLogDelta(payload):
            projectService.applyRunLogDelta(payload)

        case let .artifactsUpdated(projectID, artifact, change: _):
            upsertArtifact(projectID: projectID, artifact: artifact)

        case let .lifecycle(payload):
            chatService.applyLifecycle(payload)
        }
    }

    private func upsertProject(_ project: Project) {
        projectService.upsertProject(project)
    }

    private func upsertSession(_ session: Session) {
        projectService.upsertSession(session)
        let previousThreadId = codexThreadBySession[session.id]
        if let rawThreadId = session.codexThreadId,
           let threadId = normalizedOptionalString(rawThreadId),
           !threadId.isEmpty {
            if let previousThreadId, previousThreadId != threadId {
                codexSessionByThread[previousThreadId] = nil
            }
            codexThreadBySession[session.id] = threadId
            codexSessionByThread[threadId] = session.id
            codexPendingThreadBindingSessions.remove(session.id)
        } else {
            codexThreadBySession[session.id] = nil
            if let previousThreadId {
                codexSessionByThread[previousThreadId] = nil
            }
        }
        let permissionLevel = Self.permissionLevel(forCodexSandbox: session.codexSandbox) ?? .default
        permissionLevelBySession[session.id] = permissionLevel
        codexFullAccessBySession[session.id] = (permissionLevel == .full)
    }

    private func sessionRecord(for sessionID: UUID) -> Session? {
        for sessions in sessionsByProject.values {
            if let session = sessions.first(where: { $0.id == sessionID }) {
                return session
            }
        }
        return nil
    }

    public func backendEngine(for sessionID: UUID) -> String? {
        normalizeBackendEngine(sessionRecord(for: sessionID)?.backendEngine)
    }

    public func sessionUsesCodex(sessionID: UUID) -> Bool {
        _ = sessionID
        return true
    }

    private func upsertRun(projectID: UUID, run: RunRecord) {
        projectService.upsertRun(projectID: projectID, run: run)
    }

    private func upsertArtifact(projectID: UUID, artifact: Artifact) {
        projectService.upsertArtifactFromEvent(projectID: projectID, artifact: artifact)
    }

    public var context: AppContext {
        guard let projectID = activeProjectID else {
            return .home
        }
        guard let sessionID = activeSessionID else {
            return .project(projectID: projectID)
        }
        return .session(projectID: projectID, sessionID: sessionID)
    }

    public var activeProject: Project? {
        guard let activeProjectID else { return nil }
        return projects.first(where: { $0.id == activeProjectID })
    }

    public var activeSession: Session? {
        guard let activeProjectID, let activeSessionID else { return nil }
        return sessions(for: activeProjectID).first(where: { $0.id == activeSessionID })
    }

    public func contextRemainingFraction(for sessionID: UUID) -> Double? {
        if let usage = codexTokenUsageBySession[sessionID],
           let contextWindow = usage.contextWindowTokens,
           contextWindow > 0 {
            let used = usage.inputTokens ?? usage.totalTokens ?? 0
            let remaining = max(0, contextWindow - used)
            return min(1, max(0, Double(remaining) / Double(contextWindow)))
        }
        if sessionUsesCodex(sessionID: sessionID) {
            if let context = sessionContextBySession[sessionID],
               let contextWindow = context.contextWindowTokens,
               contextWindow > 0 {
                if let remaining = context.remainingTokens {
                    return min(1, max(0, Double(max(0, remaining)) / Double(contextWindow)))
                }
                let used = context.usedInputTokens ?? context.usedTokens
                if let used {
                    let remaining = max(0, contextWindow - used)
                    return min(1, max(0, Double(remaining) / Double(contextWindow)))
                }
            }
            return nil
        }
        return composerService.contextRemainingFraction(for: sessionID)
    }

    public func contextWindowTokens(for sessionID: UUID) -> Int? {
        if let usage = codexTokenUsageBySession[sessionID],
           let contextWindow = usage.contextWindowTokens {
            return contextWindow
        }
        if sessionUsesCodex(sessionID: sessionID) {
            return sessionContextBySession[sessionID]?.contextWindowTokens
        }
        return composerService.contextWindowTokens(for: sessionID)
    }

    public func permissionLevel(for sessionID: UUID) -> SessionPermissionLevel {
        composerService.permissionLevel(for: sessionID)
    }

    public func setPermissionLevel(projectID: UUID, sessionID: UUID, level: SessionPermissionLevel) {
        composerService.setPermissionLevel(projectID: projectID, sessionID: sessionID, level: level)
    }

    public func projectPermissionLevel(for projectID: UUID) -> SessionPermissionLevel {
        projectService.projectPermissionLevel(for: projectID)
    }

    public func setProjectPermissionLevel(projectID: UUID, level: SessionPermissionLevel) {
        projectService.setProjectPermissionLevel(projectID: projectID, level: level)
    }

    public var activeProjectSessions: [Session] {
        guard let activeProjectID else { return [] }
        return sessions(for: activeProjectID)
    }

    public var activeProjectArtifacts: [Artifact] {
        guard let activeProjectID else { return [] }
        return artifacts(for: activeProjectID)
    }

    public var activeProjectRuns: [RunRecord] {
        guard let activeProjectID else { return [] }
        return runs(for: activeProjectID)
    }

    public var activeProjectCount: Int {
        Set(homeTasks.map(\.projectID)).count
    }

    public var homeTasks: [HomeTaskRow] {
        var rows: [HomeTaskRow] = []
        for project in projects {
            let runs = runs(for: project.id)
                .filter { $0.status == .queued || $0.status == .running }
                .sorted { $0.initiatedAt > $1.initiatedAt }

            for run in runs {
                let title: String
                if run.status == .running,
                   run.currentStep > 0,
                   run.currentStep <= run.stepTitles.count {
                    title = run.stepTitles[run.currentStep - 1]
                } else {
                    title = run.stepTitles.first ?? "Run"
                }
                let progressText = run.status == .running
                    ? "Step \(run.currentStep)/\(max(run.totalSteps, 1))"
                    : "Queued"

                rows.append(
                    HomeTaskRow(
                        projectID: project.id,
                        projectName: project.name,
                        runID: run.id,
                        title: title,
                        status: run.status,
                        progressText: progressText
                    )
                )
            }
        }
        return rows
    }

    public var homePendingApprovals: [HomePendingApprovalRow] {
        var rows: [HomePendingApprovalRow] = []
        for project in projects {
            for session in sessions(for: project.id) where session.lifecycle == .active {
                let pendingCount = homePendingUserInputCount(for: session)
                guard pendingCount > 0 else { continue }
                rows.append(
                    HomePendingApprovalRow(
                        projectID: project.id,
                        projectName: project.name,
                        sessionID: session.id,
                        sessionTitle: session.title,
                        pendingCount: pendingCount,
                        pendingKind: homePendingUserInputKind(for: session),
                        updatedAt: session.updatedAt
                    )
                )
            }
        }

        return rows.sorted { lhs, rhs in
            if lhs.pendingCount != rhs.pendingCount {
                return lhs.pendingCount > rhs.pendingCount
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.sessionTitle.localizedCaseInsensitiveCompare(rhs.sessionTitle) == .orderedAscending
        }
    }

    public func sessions(for projectID: UUID) -> [Session] {
        projectService.sessions(for: projectID)
    }

    public func artifacts(for projectID: UUID) -> [Artifact] {
        projectService.artifacts(for: projectID)
    }

    public func uploadedArtifacts(for projectID: UUID) -> [Artifact] {
        projectService.uploadedArtifacts(for: projectID)
    }

    public func generatedArtifacts(for projectID: UUID) -> [Artifact] {
        projectService.generatedArtifacts(for: projectID)
    }

    public func runs(for projectID: UUID) -> [RunRecord] {
        projectService.runs(for: projectID)
    }

    public func run(runID: UUID) -> RunRecord? {
        projectService.run(runID: runID)
    }

    public func messages(for sessionID: UUID) -> [ChatMessage] {
        chatService.messages(for: sessionID)
    }

    public func codexItems(for sessionID: UUID) -> [CodexThreadItem] {
        codexItemsBySession[sessionID] ?? []
    }

    public func codexStagedImageURL(sessionID: UUID, rawPath: String) -> URL? {
        let keys = codexImagePathKeys(rawPath)
        guard !keys.isEmpty else { return nil }
        guard let map = codexStagedImageURLBySession[sessionID], !map.isEmpty else { return nil }

        for key in keys {
            guard let stagedPath = map[key] else { continue }
            if FileManager.default.fileExists(atPath: stagedPath) {
                return URL(fileURLWithPath: stagedPath)
            }
        }
        return nil
    }

    public func ensureCodexImageStagedForDisplay(sessionID: UUID, rawPath: String) {
        stageCodexImageForDisplay(sessionID: sessionID, rawPath: rawPath)
    }

    internal func stageCodexImageForDisplay(sessionID: UUID, rawPath: String) {
        Task { @MainActor [weak self] in
            _ = await self?.stageCodexImageForDisplayAsync(sessionID: sessionID, rawPath: rawPath)
        }
    }

    @discardableResult
    internal func stageCodexImageForDisplayAsync(sessionID: UUID, rawPath: String) async -> URL? {
        let keys = codexImagePathKeys(rawPath)
        guard !keys.isEmpty else { return nil }
        if let existing = codexStagedImageURL(sessionID: sessionID, rawPath: rawPath) {
            return existing
        }

        guard let canonicalPath = codexCanonicalImageFilePath(rawPath),
              codexShouldBridgeImagePath(canonicalPath)
        else {
            return nil
        }

        var inFlight = codexStagedImageInflightKeysBySession[sessionID] ?? Set()
        if inFlight.contains(canonicalPath) {
            return nil
        }
        inFlight.insert(canonicalPath)
        codexStagedImageInflightKeysBySession[sessionID] = inFlight
        defer {
            var updated = codexStagedImageInflightKeysBySession[sessionID] ?? Set()
            updated.remove(canonicalPath)
            codexStagedImageInflightKeysBySession[sessionID] = updated.isEmpty ? nil : updated
        }

        let imageData: Data? = {
            if FileManager.default.isReadableFile(atPath: canonicalPath),
               let direct = try? Data(contentsOf: URL(fileURLWithPath: canonicalPath), options: [.mappedIfSafe]) {
                return direct
            }
            return nil
        }()

        let bridgedData: Data?
        if let imageData {
            bridgedData = imageData
        } else {
            bridgedData = await codexFetchImageDataViaCommandExec(path: canonicalPath)
        }

        guard let data = bridgedData,
              codexDataLooksLikeImage(data),
              let stagedURL = codexStageImageData(data, sessionID: sessionID, sourcePath: canonicalPath)
        else {
            return nil
        }

        var byRawPath = codexStagedImageURLBySession[sessionID] ?? [:]
        for key in keys {
            byRawPath[key] = stagedURL.path
        }
        byRawPath[canonicalPath] = stagedURL.path
        byRawPath[URL(fileURLWithPath: canonicalPath).absoluteString] = stagedURL.path
        codexStagedImageURLBySession[sessionID] = byRawPath
        return stagedURL
    }

    internal func stageCodexImagesForDisplay(sessionID: UUID, items: [CodexThreadItem]) {
        for item in items {
            guard case let .imageView(imageItem) = item else { continue }
            stageCodexImageForDisplay(sessionID: sessionID, rawPath: imageItem.path)
        }
    }

    internal func clearCodexStagedImages(sessionID: UUID) {
        let directory = codexImageBridgeDirectory(sessionID: sessionID)
        try? FileManager.default.removeItem(at: directory)
        codexStagedImageURLBySession[sessionID] = nil
        codexStagedImageInflightKeysBySession[sessionID] = nil
    }

    internal func clearCodexStagedImages(sessionIDs: Set<UUID>) {
        guard !sessionIDs.isEmpty else { return }
        for sessionID in sessionIDs {
            clearCodexStagedImages(sessionID: sessionID)
        }
    }

    private func codexImagePathKeys(_ rawPath: String) -> [String] {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var keys: [String] = [trimmed]
        if let resolved = ChatImageURLResolver.resolve(trimmed) {
            keys.append(resolved.absoluteString)
            if resolved.isFileURL {
                keys.append(resolved.path)
            }
        }

        var seen: Set<String> = []
        return keys.compactMap { key in
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            guard seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private func codexCanonicalImageFilePath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("~/"), trimmed.count > 2 {
            return trimmed
        }

        guard let resolved = ChatImageURLResolver.resolve(trimmed), resolved.isFileURL else {
            return nil
        }
        let path = resolved.path.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func codexShouldBridgeImagePath(_ filePath: String) -> Bool {
        let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
        return Self.codexSupportedImageExtensions.contains(ext)
    }

    private func codexImageBridgeDirectory(sessionID: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.codexImageBridgeDirectoryName, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
    }

    private func codexStageImageData(
        _ data: Data,
        sessionID: UUID,
        sourcePath: String
    ) -> URL? {
        let directory = codexImageBridgeDirectory(sessionID: sessionID)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let ext = URL(fileURLWithPath: sourcePath).pathExtension.lowercased()
        let safeExt = Self.codexSupportedImageExtensions.contains(ext) ? ext : "png"
        let originalName = URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent
        let normalizedName = originalName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^a-zA-Z0-9._-]+"#, with: "-", options: .regularExpression)
        let fileName = "\(UUID().uuidString)-\(normalizedName.isEmpty ? "image" : normalizedName)"
        let fileURL = directory
            .appendingPathComponent(fileName)
            .appendingPathExtension(safeExt)

        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    private func codexFetchImageDataViaCommandExec(path: String) async -> Data? {
        let escapedPath = Self.shellSingleQuoted(path)
        let script = """
        p=\(escapedPath)
        case "$p" in
          \\~/*) p="$HOME/${p#~/}" ;;
        esac
        if [ -r "$p" ]; then
          base64 -i "$p" 2>/dev/null || base64 "$p" 2>/dev/null
        fi
        """

        do {
            let response = try await requestCodex(
                method: "command/exec",
                params: CodexCommandExecParams(
                    command: ["/bin/sh", "-lc", script],
                    timeoutMs: 12_000,
                    cwd: nil
                )
            )
            let payload: CodexCommandExecResponse = try decodeCodexResult(response.result)
            guard payload.exitCode == 0 else { return nil }
            let base64 = payload.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base64.isEmpty else { return nil }
            return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
        } catch {
            return nil
        }
    }

    private func codexDataLooksLikeImage(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
#if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        return CGImageSourceGetCount(source) > 0
#else
        return true
#endif
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public func codexRunningCommandsEligibleForShelf(
        sessionID: UUID,
        now: Date = .now,
        minimumDurationMs: Int = 10_000
    ) -> [CodexCommandExecutionItem] {
        let thresholdMs = max(minimumDurationMs, 0)
        let startedAtByCommandID = codexCommandNoResultStartedAtBySession[sessionID] ?? [:]

        return codexItems(for: sessionID).compactMap { item in
            guard case let .commandExecution(command) = item else { return nil }
            guard Self.isInProgressCommandStatus(command.status) else { return nil }
            guard Self.commandHasNoResult(command) else { return nil }

            let elapsedMs: Int
            if let durationMs = command.durationMs, durationMs > 0 {
                elapsedMs = durationMs
            } else if let startedAt = startedAtByCommandID[command.id] {
                elapsedMs = max(0, Int(now.timeIntervalSince(startedAt) * 1_000))
            } else {
                elapsedMs = 0
            }

            guard elapsedMs >= thresholdMs else { return nil }
            return command
        }
    }

    public func codexPendingApprovals(for sessionID: UUID) -> [CodexPendingApproval] {
        codexPendingApprovalsBySession[sessionID] ?? []
    }

    public func codexPendingPrompt(for sessionID: UUID) -> CodexPendingPrompt? {
        codexPendingPromptBySession[sessionID]?.first
    }

    public func codexPendingPromptQueue(for sessionID: UUID) -> [CodexPendingPrompt] {
        codexPendingPromptBySession[sessionID] ?? []
    }

    private func homePendingUserInputCount(for session: Session) -> Int {
        if let sessionCount = session.pendingUserInputCount, sessionCount > 0 {
            return sessionCount
        }
        var count = 0
        count += codexPendingPromptQueue(for: session.id).count
        count += codexPendingApprovals(for: session.id).count
        if pendingApproval(for: session.id) != nil {
            count += 1
        }
        return count
    }

    private func homePendingUserInputKind(for session: Session) -> String? {
        if let rawKind = session.pendingUserInputKind,
           let kind = normalizedOptionalString(rawKind) {
            return kind
        }
        if let prompt = codexPendingPrompt(for: session.id) {
            return normalizedOptionalString(prompt.kind) ?? "prompt"
        }
        if !codexPendingApprovals(for: session.id).isEmpty {
            return "approval"
        }
        if pendingApproval(for: session.id) != nil {
            return "plan"
        }
        return nil
    }

    public func codexPromptDraft(
        sessionID: UUID,
        requestID: CodexRequestID
    ) -> CodexPromptDraftState? {
        let key = codexPromptDraftDefaultsKey(sessionID: sessionID, requestID: requestID)
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? gatewayJSONDecoder.decode(CodexPromptDraftState.self, from: data)
    }

    public func saveCodexPromptDraft(
        sessionID: UUID,
        requestID: CodexRequestID,
        draft: CodexPromptDraftState
    ) {
        let key = codexPromptDraftDefaultsKey(sessionID: sessionID, requestID: requestID)
        if let data = try? gatewayJSONEncoder.encode(draft) {
            defaults.set(data, forKey: key)
        }
    }

    public func clearCodexPromptDraft(sessionID: UUID, requestID: CodexRequestID) {
        let key = codexPromptDraftDefaultsKey(sessionID: sessionID, requestID: requestID)
        defaults.removeObject(forKey: key)
    }

    public func codexQueuedInputs(for sessionID: UUID) -> [CodexQueuedUserInputItem] {
        ensureCodexQueuedInputsLoaded(sessionID: sessionID)
        return (codexQueuedInputsBySession[sessionID] ?? []).sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex {
                return lhs.sortIndex < rhs.sortIndex
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func moveCodexQueuedInputs(sessionID: UUID, from: IndexSet, to: Int) {
        ensureCodexQueuedInputsLoaded(sessionID: sessionID)
        var ordered = codexQueuedInputs(for: sessionID)
        Self.moveArray(&ordered, from: from, to: to)
        // Keep the moved order; only reindex sortIndex.
        codexQueuedInputsBySession[sessionID] = ordered.enumerated().map { index, item in
            var updated = item
            updated.sortIndex = index
            return updated
        }
        persistCodexQueuedInputs(sessionID: sessionID)
    }

    public func updateCodexQueuedInput(sessionID: UUID, item: CodexQueuedUserInputItem) {
        ensureCodexQueuedInputsLoaded(sessionID: sessionID)
        var items = codexQueuedInputsBySession[sessionID] ?? []
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }

        let previous = items[index]
        let nextStoredPaths = Set(item.attachments.map { $0.storedPath.trimmingCharacters(in: .whitespacesAndNewlines) })
        for attachment in previous.attachments {
            let stored = attachment.storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stored.isEmpty else { continue }
            guard !nextStoredPaths.contains(stored) else { continue }
            try? FileManager.default.removeItem(atPath: stored)
        }

        items[index] = item
        codexQueuedInputsBySession[sessionID] = normalizeCodexQueuedInputs(items)
        persistCodexQueuedInputs(sessionID: sessionID)
    }

    public func codexTurnDiff(for sessionID: UUID) -> CodexTurnDiffState? {
        codexTurnDiffBySession[sessionID]
    }

    public func codexSkillsState(for sessionID: UUID) -> CodexSkillsListState {
        codexSkillsStateBySession[sessionID] ?? CodexSkillsListState()
    }

    public func refreshCodexSkills(sessionID: UUID, cwds: [String]? = nil, forceReload: Bool = false) {
        guard sessionUsesCodex(sessionID: sessionID) else { return }
        var state = codexSkillsStateBySession[sessionID] ?? CodexSkillsListState()
        if state.isLoading {
            // Prevent duplicate in-flight refreshes; use forceReload to explicitly refresh.
            if forceReload == false { return }
        }
        state.isLoading = true
        state.error = nil
        codexSkillsStateBySession[sessionID] = state

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await self.requestCodex(
                    method: "skills/list",
                    params: CodexSkillsListParams(cwds: cwds, forceReload: forceReload)
                )
                let entries = try self.decodeCodexSkillsEntries(response.result)
                self.codexSkillsStateBySession[sessionID] = CodexSkillsListState(
                    isLoading: false,
                    entries: entries,
                    error: nil,
                    updatedAt: Date()
                )
            } catch {
                var failure = self.codexSkillsStateBySession[sessionID] ?? CodexSkillsListState()
                failure.isLoading = false
                failure.error = self.normalizeCodexSkillsErrorMessage(error)
                self.codexSkillsStateBySession[sessionID] = failure
            }
        }
    }

    public func codexActiveTurnID(for sessionID: UUID) -> String? {
        codexActiveTurnIDBySession[sessionID]
    }

    public func canInterruptCodexTurn(sessionID: UUID) -> Bool {
        guard let rawTurnID = codexActiveTurnIDBySession[sessionID] else { return false }
        return normalizedOptionalString(rawTurnID) != nil
    }

    public func codexTurnInFlight(sessionID: UUID) -> Bool {
        if streamingSessions.contains(sessionID) {
            return true
        }

        if canInterruptCodexTurn(sessionID: sessionID) {
            return true
        }

        let normalizedStatus = codexStatusTextBySession[sessionID]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch normalizedStatus {
        case "inprogress", "in_progress", "running", "thinking":
            return true
        default:
            return false
        }
    }

    public func sessionNeedsUserInput(sessionID: UUID) -> Bool {
        if pendingApproval(for: sessionID) != nil {
            return true
        }
        if codexPendingPrompt(for: sessionID) != nil {
            return true
        }
        if !codexPendingApprovals(for: sessionID).isEmpty {
            return true
        }
        if let session = sessionRecord(for: sessionID) {
            if session.hasPendingUserInput == true {
                return true
            }
            if let count = session.pendingUserInputCount, count > 0 {
                return true
            }
        }
        return false
    }

    public func codexStatusText(for sessionID: UUID) -> String? {
        codexStatusTextBySession[sessionID]
    }

    public func codexInterruptedTurnIDs(sessionID: UUID) -> Set<String> {
        codexInterruptedTurnIDsBySession[sessionID] ?? []
    }

    internal func suppressCodexTurn(sessionID: UUID, turnID: String) {
        let normalized = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var suppressed = codexSuppressedTurnIDsBySession[sessionID] ?? Set()
        suppressed.insert(normalized)
        codexSuppressedTurnIDsBySession[sessionID] = suppressed
    }

    internal func unsuppressCodexTurn(sessionID: UUID, turnID: String) {
        let normalized = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard var suppressed = codexSuppressedTurnIDsBySession[sessionID] else { return }
        suppressed.remove(normalized)
        codexSuppressedTurnIDsBySession[sessionID] = suppressed.isEmpty ? nil : suppressed
    }

    internal func isCodexTurnSuppressed(sessionID: UUID, turnID: String) -> Bool {
        let normalized = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return codexSuppressedTurnIDsBySession[sessionID]?.contains(normalized) == true
    }

    public func codexTrajectoryDurations(sessionID: UUID) -> [String: Int] {
        codexTrajectoryDurationsBySession[sessionID] ?? [:]
    }

    public func codexTrajectoryDuration(sessionID: UUID, turnID: String) -> Int? {
        let normalizedTurnID = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTurnID.isEmpty else { return nil }
        return codexTrajectoryDurationsBySession[sessionID]?[normalizedTurnID]
    }

    public func setCodexTrajectoryDuration(sessionID: UUID, turnID: String, durationMs: Int) {
        let normalizedTurnID = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTurnID.isEmpty else { return }
        guard durationMs > 0 else { return }

        var turnDurations = codexTrajectoryDurationsBySession[sessionID] ?? [:]
        if let existing = turnDurations[normalizedTurnID], existing >= durationMs {
            return
        }
        turnDurations[normalizedTurnID] = durationMs
        codexTrajectoryDurationsBySession[sessionID] = turnDurations
        persistCodexTrajectoryDurations()
    }

    internal func clearCodexTrajectoryDurations(sessionID: UUID) {
        codexTrajectoryDurationsBySession[sessionID] = nil
        persistCodexTrajectoryDurations()
    }

    internal func clearCodexTrajectoryDurations(sessionIDs: Set<UUID>) {
        guard !sessionIDs.isEmpty else { return }
        for sessionID in sessionIDs {
            codexTrajectoryDurationsBySession[sessionID] = nil
        }
        persistCodexTrajectoryDurations()
    }

    internal func clearCodexTurnLifecycleState(sessionID: UUID, threadID: String? = nil) {
        codexTrajectoryStartedAtBySession[sessionID] = nil
        codexCommandNoResultStartedAtBySession[sessionID] = nil
        clearCodexStagedImages(sessionID: sessionID)

        let resolvedThreadID: String? = {
            if let threadID,
               let normalizedThreadID = normalizedOptionalString(threadID) {
                return normalizedThreadID
            }
            if let mappedThreadID = codexThreadBySession[sessionID],
               let normalizedMappedThreadID = normalizedOptionalString(mappedThreadID) {
                return normalizedMappedThreadID
            }
            return nil
        }()

        guard let resolvedThreadID else { return }
        let prefix = "\(resolvedThreadID)|"

        codexFirstUserMessageIDByScopedBackendTurn = codexFirstUserMessageIDByScopedBackendTurn.filter { key, _ in
            !key.hasPrefix(prefix)
        }
        codexTurnStartedAtByScopedBackendTurn = codexTurnStartedAtByScopedBackendTurn.filter { key, _ in
            !key.hasPrefix(prefix)
        }
        codexPendingDurationMsByScopedBackendTurn = codexPendingDurationMsByScopedBackendTurn.filter { key, _ in
            !key.hasPrefix(prefix)
        }
    }

    public func codexFullAccessEnabled(for sessionID: UUID) -> Bool {
        codexFullAccessBySession[sessionID] ?? false
    }

    public func respondToCodexApproval(
        sessionID: UUID,
        requestID: CodexRequestID,
        decision: String
    ) {
        Task { [weak self] in
            guard let self else { return }
            self.resumeStreamingForActiveTurnIfNeeded(sessionID: sessionID)

            guard let codexClient = self.codexClient else { return }
            let result = JSONValue.object(["decision": .string(decision)])
            try? await codexClient.respond(result: result, for: requestID)
            var approvals = self.codexPendingApprovalsBySession[sessionID] ?? []
            approvals.removeAll { $0.requestID == requestID }
            self.codexPendingApprovalsBySession[sessionID] = approvals
            self.refreshSessionPendingUserInputMetadata(sessionID: sessionID)
        }
    }

    public func respondToCodexPrompt(
        sessionID: UUID,
        requestID: CodexRequestID,
        answers: [String: [String]]
    ) {
        Task { [weak self] in
            guard let self else { return }
            self.applyPlanModeAfterCodexPromptResponseIfNeeded(
                sessionID: sessionID,
                requestID: requestID,
                answers: answers
            )
            if self.shouldResumeStreamingAfterPromptResponse(
                sessionID: sessionID,
                requestID: requestID,
                answers: answers
            ) {
                self.resumeStreamingForActiveTurnIfNeeded(sessionID: sessionID)
            } else {
                self.pauseStreamingForUserInput(sessionID: sessionID)
            }

            var nestedAnswers: [String: JSONValue] = [:]
            for (questionID, answerList) in answers {
                let normalizedQuestionID = questionID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedQuestionID.isEmpty else { continue }
                let normalizedAnswers = answerList.compactMap { answer -> JSONValue? in
                    let normalizedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalizedAnswer.isEmpty else { return nil }
                    return .string(normalizedAnswer)
                }
                guard !normalizedAnswers.isEmpty else { continue }
                nestedAnswers[normalizedQuestionID] = .object([
                    "answers": .array(normalizedAnswers),
                ])
            }
            let payload = JSONValue.object([
                "answers": .object(nestedAnswers),
            ])

            if let override = self.codexServerResponseOverrideForTests {
                override(requestID, payload, nil)
                self.dequeueCodexPendingPrompt(sessionID: sessionID, requestID: requestID)
                self.applyE2EPlanPromptFlowAfterResponseIfNeeded(sessionID: sessionID)
                return
            }

            if let codexClient = self.codexClient {
                try? await codexClient.respond(result: payload, for: requestID)
            }
            self.dequeueCodexPendingPrompt(sessionID: sessionID, requestID: requestID)
            self.applyE2EPlanPromptFlowAfterResponseIfNeeded(sessionID: sessionID)
        }
    }

    private static let planImplementationDecisionQuestionID = "labos_plan_implementation_decision"
    private static let planImplementationApprovalAnswers: Set<String> = [
        "yes, implement this plan",
        "yes implement this plan",
        "implement now",
        "implement plan",
        "implement it",
    ]

    private static func normalizedPlanImplementationDecision(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[.!?]+$", with: "", options: .regularExpression)
    }

    private static func isPlanImplementationApprovalDecision(_ raw: String) -> Bool {
        let normalizedDecision = normalizedPlanImplementationDecision(raw)
        return planImplementationApprovalAnswers.contains(normalizedDecision)
    }

    private func applyPlanModeAfterCodexPromptResponseIfNeeded(
        sessionID: UUID,
        requestID: CodexRequestID,
        answers: [String: [String]]
    ) {
        let queuedPrompt = codexPendingPromptBySession[sessionID]?.first(where: { $0.requestID == requestID })
        let isImplementConfirmation = queuedPrompt?.kind == "implement_confirmation"
            || answers.keys.contains(Self.planImplementationDecisionQuestionID)
        guard isImplementConfirmation else { return }
        guard let decision = firstNormalizedAnswer(
            for: Self.planImplementationDecisionQuestionID,
            in: answers
        )
        else {
            return
        }
        if Self.isPlanImplementationApprovalDecision(decision) {
            setPlanModeEnabled(for: sessionID, enabled: false)
            return
        }
        setPlanModeEnabled(for: sessionID, enabled: true)
    }

    public func pendingComposerAttachments(for sessionID: UUID) -> [ComposerAttachment] {
        composerService.pendingComposerAttachments(for: sessionID)
    }

    public func addPendingComposerAttachments(sessionID: UUID, attachments: [ComposerAttachment]) {
        composerService.addPendingComposerAttachments(sessionID: sessionID, attachments: attachments)
    }

    public func removePendingComposerAttachment(sessionID: UUID, attachmentID: UUID) {
        composerService.removePendingComposerAttachment(sessionID: sessionID, attachmentID: attachmentID)
    }

    public func clearPendingComposerAttachments(sessionID: UUID) {
        composerService.clearPendingComposerAttachments(sessionID: sessionID)
    }

    public func attachmentPayload(for sessionID: UUID, messageID: UUID) -> [ComposerAttachment] {
        composerService.attachmentPayload(for: sessionID, messageID: messageID)
    }

    static func messageDisplayOrder(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func mergeArtifactRefsPreservingInlineForGatewayEcho(
        remoteArtifactRefs: [ChatArtifactReference],
        localArtifactRefs: [ChatArtifactReference]
    ) -> [ChatArtifactReference] {
        guard !remoteArtifactRefs.isEmpty else { return localArtifactRefs }
        guard !localArtifactRefs.isEmpty else { return remoteArtifactRefs }

        func key(for ref: ChatArtifactReference) -> String {
            if let artifactID = ref.artifactID {
                return "id:\(artifactID.uuidString.lowercased())"
            }
            let normalizedProject = ref.projectID.uuidString.lowercased()
            let normalizedPath = ref.path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let normalizedDisplay = ref.displayText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return "path:\(normalizedProject)|\(normalizedPath)|\(normalizedDisplay)"
        }

        var localByKey: [String: ChatArtifactReference] = [:]
        for localRef in localArtifactRefs {
            localByKey[key(for: localRef)] = localRef
        }

        return remoteArtifactRefs.map { remoteRef in
            guard let localRef = localByKey[key(for: remoteRef)] else { return remoteRef }
            var merged = remoteRef
            if merged.inlineDataBase64 == nil {
                merged.inlineDataBase64 = localRef.inlineDataBase64
            }
            if merged.byteCount == nil {
                merged.byteCount = localRef.byteCount
            }
            if merged.mimeType == nil {
                merged.mimeType = localRef.mimeType
            }
            if merged.sourceName == nil {
                merged.sourceName = localRef.sourceName
            }
            if merged.scope == nil {
                merged.scope = localRef.scope
            }
            return merged
        }
    }

    public func liveAgentEvents(for sessionID: UUID) -> [AgentLiveEvent] {
        chatService.liveAgentEvents(for: sessionID)
    }

    public func activeInlineProcess(for sessionID: UUID) -> ActiveInlineProcess? {
        chatService.activeInlineProcess(for: sessionID)
    }

    public func pendingInlineProcess(for sessionID: UUID) -> ActiveInlineProcess? {
        chatService.pendingInlineProcess(for: sessionID)
    }

    public func activeInlineProcess(for sessionID: UUID, assistantMessageID: UUID) -> ActiveInlineProcess? {
        chatService.activeInlineProcess(for: sessionID, assistantMessageID: assistantMessageID)
    }

    public func persistedProcessSummary(for assistantMessageID: UUID) -> AssistantProcessSummary? {
        chatService.persistedProcessSummary(for: assistantMessageID)
    }

    public func retrySourceText(for messageID: UUID, in sessionID: UUID) -> String? {
        chatService.retrySourceText(for: messageID, in: sessionID)
    }

    public func retryMessage(
        projectID: UUID,
        sessionID: UUID,
        fromMessageID messageID: UUID,
        modelIdOverride: String? = nil
    ) {
        chatService.retryMessage(projectID: projectID, sessionID: sessionID, fromMessageID: messageID, modelIdOverride: modelIdOverride)
    }

    public func overwriteUserMessage(
        projectID: UUID,
        sessionID: UUID,
        messageID: UUID,
        text: String
    ) {
        chatService.overwriteUserMessage(projectID: projectID, sessionID: sessionID, messageID: messageID, text: text)
    }

    @discardableResult
    public func branchFromMessage(
        projectID: UUID,
        sessionID: UUID,
        fromMessageID messageID: UUID,
        modelIdOverride: String? = nil
    ) async -> Session? {
        await chatService.branchFromMessage(projectID: projectID, sessionID: sessionID, fromMessageID: messageID, modelIdOverride: modelIdOverride)
    }

    public func pendingApproval(for sessionID: UUID) -> PendingApproval? {
        planService.pendingApproval(for: sessionID)
    }

    public func pendingPlan(for sessionID: UUID) -> ExecutionPlan? {
        planService.pendingPlan(for: sessionID)
    }

    public func planModeEnabled(for sessionID: UUID) -> Bool {
        composerService.planModeEnabled(for: sessionID)
    }

    public func setPlanModeEnabled(for sessionID: UUID, enabled: Bool) {
        composerService.setPlanModeEnabled(for: sessionID, enabled: enabled)
    }

    public func selectedModelId(for sessionID: UUID) -> String {
        composerService.selectedModelId(for: sessionID)
    }

    public func setSelectedModelId(for sessionID: UUID, modelId: String) {
        composerService.setSelectedModelId(for: sessionID, modelId: modelId)
    }

    public func selectedModelInfo(for sessionID: UUID) -> GatewayModelInfo? {
        composerService.selectedModelInfo(for: sessionID)
    }

    public func selectedThinkingLevel(for sessionID: UUID) -> ThinkingLevel? {
        composerService.selectedThinkingLevel(for: sessionID)
    }

    public func setSelectedThinkingLevel(for sessionID: UUID, level: ThinkingLevel?) {
        composerService.setSelectedThinkingLevel(for: sessionID, level: level)
    }

    @discardableResult
    public func createProject(name: String) async -> Project? {
        await projectService.createProject(name: name)
    }

    public func renameProject(projectID: UUID, newName: String) {
        projectService.renameProject(projectID: projectID, newName: newName)
    }

    public func deleteProject(projectID: UUID) {
        projectService.deleteProject(projectID: projectID)
    }

    private func removeProjectLocally(projectID: UUID) {
        projectService.removeProjectLocally(projectID: projectID)
    }

    public func openProject(projectID: UUID) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        activeProjectID = projectID
        activeSessionID = nil

        for (id, task) in chatService.sessionHistoryPrefetchTasksByProject where id != projectID {
            task.cancel()
            chatService.sessionHistoryPrefetchTasksByProject[id] = nil
        }

        if shouldUseCodexRPC {
            Task { [weak self] in
                guard let self else { return }
                await self.refreshProjectFromCodex(projectID: projectID)
            }
        } else if isGatewayConnected {
            chatService.scheduleSessionHistoryPrefetch(projectID: projectID)
            Task { [weak self] in
                guard let self else { return }
                await self.refreshProjectFromGateway(projectID: projectID)
                self.chatService.scheduleSessionHistoryPrefetch(projectID: projectID)
            }
        }
    }

    public func openSession(projectID: UUID, sessionID: UUID) {
        guard sessions(for: projectID).contains(where: { $0.id == sessionID }) else { return }
        activeProjectID = projectID
        activeSessionID = sessionID
        ensureComposerPrefs(sessionID: sessionID)

        if sessionUsesCodex(sessionID: sessionID) {
            if let threadId = codexThreadBySession[sessionID] {
                codexSessionByThread[threadId] = sessionID
            }
            Task { [weak self] in
                await self?.chatService.refreshSessionHistoryFromCodex(
                    projectID: projectID,
                    sessionID: sessionID,
                    trigger: .interactive
                )
            }
        } else if isGatewayConnected {
            Task { [weak self] in
                await self?.chatService.refreshSessionHistoryFromGateway(projectID: projectID, sessionID: sessionID, trigger: .interactive)
            }
        }
    }

    public func backToProjects() {
        activeProjectID = nil
        activeSessionID = nil
    }

    public func backToProject() {
        activeSessionID = nil
    }

    @discardableResult
    public func createSession(projectID: UUID, title: String? = nil) async -> Session? {
        await projectService.createSession(projectID: projectID, title: title)
    }

    public func updateSessionBackend(projectID: UUID, sessionID: UUID, backendEngine: String) async {
        await projectService.updateSessionBackend(projectID: projectID, sessionID: sessionID, backendEngine: backendEngine)
    }

    public func createSessionAndSend(projectID: UUID, firstMessage: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let session = await createSession(projectID: projectID, title: nil) else { return }
            chatService.sendMessage(projectID: session.projectID, sessionID: session.id, text: firstMessage)
        }
    }

    public func uploadProjectFiles(projectID: UUID, files: [ProjectUploadFile], createdBySessionID: UUID?) async {
        await projectService.uploadProjectFiles(projectID: projectID, files: files, createdBySessionID: createdBySessionID)
    }

    public func addUploadedFiles(projectID: UUID, fileNames: [String], createdBySessionID: UUID?) {
        projectService.addUploadedFiles(projectID: projectID, fileNames: fileNames, createdBySessionID: createdBySessionID)
    }

    public func removeUploadedFile(projectID: UUID, path: String) {
        projectService.removeUploadedFile(projectID: projectID, path: path)
    }


    public func renameSession(projectID: UUID, sessionID: UUID, newTitle: String) {
        projectService.renameSession(projectID: projectID, sessionID: sessionID, newTitle: newTitle)
    }

    public func archiveSession(projectID: UUID, sessionID: UUID) {
        projectService.archiveSession(projectID: projectID, sessionID: sessionID)
    }

    public func unarchiveSession(projectID: UUID, sessionID: UUID) {
        projectService.unarchiveSession(projectID: projectID, sessionID: sessionID)
    }

    // Session deletion removes conversation state only. Project artifacts remain untouched.
    public func deleteSession(projectID: UUID, sessionID: UUID) {
        projectService.deleteSession(projectID: projectID, sessionID: sessionID)
    }

    private func removeSessionLocally(projectID: UUID, sessionID: UUID) {
        projectService.removeSessionLocally(projectID: projectID, sessionID: sessionID)
    }

    public func sendMessage(
        projectID: UUID,
        sessionID: UUID,
        text: String,
        attachments: [ComposerAttachment]? = nil
    ) {
        chatService.sendMessage(projectID: projectID, sessionID: sessionID, text: text, attachments: attachments)
    }

    public func interruptCodexTurn(sessionID: UUID) {
        chatService.interruptCodexTurn(sessionID: sessionID)
    }

    public func steerQueuedCodexInput(sessionID: UUID, queueItemID: UUID) {
        chatService.steerQueuedCodexInput(sessionID: sessionID, queueItemID: queueItemID)
    }

    public func removeQueuedCodexInput(sessionID: UUID, queueItemID: UUID) {
        chatService.removeQueuedCodexInput(sessionID: sessionID, queueItemID: queueItemID)
    }

    static func shouldAutoRecoverMissingGatewaySession(localNonSystemMessageCount: Int) -> Bool {
        localNonSystemMessageCount <= 1
    }

    nonisolated public static func shouldAutoScrollOnInitialAppear(hasMessages: Bool) -> Bool {
        hasMessages
    }

    nonisolated public static func shouldAutoScrollOnIncomingMessage() -> Bool {
        false
    }

    nonisolated public static func shouldAutoScrollOnIncomingDelta() -> Bool {
        false
    }

    nonisolated public static func shouldAutoScrollWhenStreamingCompletes() -> Bool {
        false
    }

    func isGatewayProjectNotFoundError(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("project") && (lower.contains("not found") || lower.contains("cannot find"))
    }

    func isGatewaySessionNotFoundError(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("session") && lower.contains("not found")
    }

    func shouldSetGatewayFailedState(for error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("not found") || lower.contains("cannot find") {
            return false
        }
        if lower.contains("bad request") || lower.contains("missing ") || lower.contains("invalid ") {
            return false
        }
        return true
    }

    func resolveGatewayProjectIDForCreate(
        requestedProjectID: UUID,
        fallbackProjectName: String?
    ) async -> UUID? {
        let normalizedName = fallbackProjectName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isGatewayConnected, let gatewayClient else { return nil }

        // Fetch remote projects without mutating local UI state (important during chat sends).
        struct EmptyParams: Codable, Sendable {}
        let remoteProjects: [Project]
        do {
            let res = try await gatewayClient.request(method: "projects.list", params: EmptyParams())
            remoteProjects = try decodeGatewayPayload(res.payload, key: "projects")
        } catch {
            lastGatewayErrorMessage = error.localizedDescription
            return nil
        }

        if let match = remoteProjects.first(where: { $0.id == requestedProjectID }) {
            upsertProject(match)
            return match.id
        }

        if let normalizedName, !normalizedName.isEmpty,
           let match = remoteProjects.first(where: {
               $0.name.compare(normalizedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
           }) {
            upsertProject(match)
            return match.id
        }

        if let activeProjectID,
           let match = remoteProjects.first(where: { $0.id == activeProjectID }) {
            upsertProject(match)
            return match.id
        }

        // Last-resort recovery: if the local project is missing remotely, create a matching
        // remote project so "send from project page" can always proceed.
        if let normalizedName, !normalizedName.isEmpty,
           let createdProjectID = await createGatewayProjectForMissingLocalProject(name: normalizedName) {
            return createdProjectID
        }

        if let first = remoteProjects.first {
            upsertProject(first)
            return first.id
        }

        return nil
    }

    func createGatewayProjectForMissingLocalProject(name: String) async -> UUID? {
        guard isGatewayConnected, let gatewayClient else { return nil }

        struct Params: Codable, Sendable {
            var name: String
        }

        do {
            let res = try await gatewayClient.request(method: "projects.create", params: Params(name: name))
            let project: Project = try decodeGatewayPayload(res.payload, key: "project")
            lastGatewayErrorMessage = nil
            upsertProject(project)
            sessionsByProject[project.id] = sessionsByProject[project.id] ?? []
            artifactsByProject[project.id] = artifactsByProject[project.id] ?? []
            runsByProject[project.id] = runsByProject[project.id] ?? []
            return project.id
        } catch {
            lastGatewayErrorMessage = error.localizedDescription
            return nil
        }
    }

    public func cancelPlan(sessionID: UUID) {
        planService.cancelPlan(sessionID: sessionID)
    }

    public func approvePlan(sessionID: UUID, judgmentResponses: JudgmentResponses? = nil) {
        planService.approvePlan(sessionID: sessionID, judgmentResponses: judgmentResponses)
    }

    public func openResults() {
        rightPanelTab = .artifacts
        isLeftPanelOpen = false
        isRightPanelOpen = true
    }

    public func openResults(tab: ResultsTab) {
        _ = tab
        openResults()
    }

    public func closeResults() {
        isRightPanelOpen = false
    }

    public func openLeftPanel() {
        isRightPanelOpen = false
        isLeftPanelOpen = true
    }

    public func closeLeftPanel() {
        isLeftPanelOpen = false
    }

    public func openArtifactReference(_ reference: ChatArtifactReference) {
        activeProjectID = reference.projectID
        selectedArtifactPath = reference.path
        openResults()
        setTemporaryArtifactHighlight(reference.path)
    }

    public func openArtifact(projectID: UUID, path: String) {
        activeProjectID = projectID
        selectedArtifactPath = path
        openResults()
        setTemporaryArtifactHighlight(path)
    }

    public func openRun(projectID: UUID, runID: UUID) {
        activeProjectID = projectID
        selectedRunID = runID

        let matchedRun = runs(for: projectID).first(where: { $0.id == runID })
        if let sessionID = matchedRun?.sessionID,
           sessions(for: projectID).contains(where: { $0.id == sessionID }) {
            activeSessionID = sessionID
        } else {
            activeSessionID = nil
        }
    }

    public func handleDeepLink(_ url: URL) {
        guard let link = DeepLinkCodec.parse(url: url) else { return }
        switch link {
        case let .artifact(projectID, path):
            openArtifact(projectID: projectID, path: path)
        case let .run(projectID, runID):
            openRun(projectID: projectID, runID: runID)
        case let .session(projectID, sessionID):
            if sessions(for: projectID).contains(where: { $0.id == sessionID }) {
                openSession(projectID: projectID, sessionID: sessionID)
                return
            }
            activeProjectID = projectID
            Task { [weak self] in
                guard let self else { return }
                if self.shouldUseCodexRPC {
                    await self.refreshProjectFromCodex(projectID: projectID)
                } else if self.isGatewayConnected {
                    await self.refreshProjectFromGateway(projectID: projectID)
                }
                if self.sessions(for: projectID).contains(where: { $0.id == sessionID }) {
                    self.openSession(projectID: projectID, sessionID: sessionID)
                } else {
                    self.openProject(projectID: projectID)
                }
            }
        }
    }

    public func runLabel(for run: RunRecord) -> String {
        projectService.runLabel(for: run)
    }

    public func fetchArtifactContent(projectID: UUID, path: String) async -> String {
        await projectService.fetchArtifactContent(projectID: projectID, path: path)
    }

        public func fetchArtifactData(projectID: UUID, path: String) async -> Data? {
        await projectService.fetchArtifactData(projectID: projectID, path: path)
    }

    private func ensureComposerPrefs(sessionID: UUID) {
        composerService.ensureComposerPrefs(sessionID: sessionID)
    }

    private func setTemporaryArtifactHighlight(_ path: String) {
        projectService.setTemporaryArtifactHighlight(path)
    }

    private func seedDemoData() {
        let project = Project(name: "Agentic Research Sandbox")
        projects = [project]

        let session = Session(projectID: project.id, title: "Initial Research Session")
        sessionsByProject[project.id] = [session]

        let artifacts: [Artifact] = [
            Artifact(projectID: project.id, path: "uploads/market_data.csv", origin: .userUpload, sizeBytes: 5_421),
            Artifact(projectID: project.id, path: "notebooks/analysis.ipynb", origin: .generated, sizeBytes: 34_120, createdBySessionID: session.id),
            Artifact(projectID: project.id, path: "figures/summary.png", origin: .generated, sizeBytes: 190_442, createdBySessionID: session.id),
            Artifact(projectID: project.id, path: "logs/run.log", origin: .generated, sizeBytes: 12_011, createdBySessionID: session.id)
        ]
        artifactsByProject[project.id] = artifacts

        let run = RunRecord(
            projectID: project.id,
            sessionID: session.id,
            status: .running,
            currentStep: 2,
            totalSteps: 5,
            logSnippet: "Python runtime using uploads/source.csv to compute features.",
            stepTitles: ["Fetch source data", "Compute features", "Train model", "Evaluate", "Render report"],
            stepDetails: [
                "Download runtime pulling remote source data into uploads/source.csv.",
                "Python runtime using uploads/source.csv to compute features.",
                "Python runtime training the model from computed features.",
                "Notebook runtime evaluating model performance metrics.",
                "Notebook runtime rendering summary report and figures."
            ],
            activity: [
                RunActionEvent(
                    type: .toolCall,
                    summary: "Step 1/5 · Download tool",
                    detail: "Fetch source data"
                ),
                RunActionEvent(
                    type: .command,
                    summary: "Command executed",
                    detail: "curl -L \"https://example.com/source.csv\" -o uploads/source.csv"
                ),
                RunActionEvent(
                    type: .output,
                    summary: "Output updated",
                    detail: "uploads/source.csv"
                ),
                RunActionEvent(
                    type: .toolCall,
                    summary: "Step 2/5 · Python tool",
                    detail: "Compute features"
                ),
                RunActionEvent(
                    type: .command,
                    summary: "Command executed",
                    detail: "python scripts/compute_features.py --input uploads/source.csv --output artifacts/features.parquet"
                )
            ],
            producedArtifactPaths: ["uploads/market_data.csv"]
        )
        runsByProject[project.id] = [run]

        let welcome = ChatMessage(
            sessionID: session.id,
            role: .assistant,
            text: "Welcome back. Ask for a plan and I will request confirmation before execution."
        )
        let seedLog1 = ChatMessage(
            sessionID: session.id,
            role: .tool,
            text: "Tool call · Step 1/5: Download\nFetched source data metadata and prepared download target."
        )
        let seedLog2 = ChatMessage(
            sessionID: session.id,
            role: .tool,
            text: "Command executed: curl -L \"https://example.com/source.csv\" -o uploads/source.csv\nDownloaded 1.8 MB (52431 rows) into uploads/source.csv."
        )
        let seedLog3 = ChatMessage(
            sessionID: session.id,
            role: .tool,
            text: "Tool call · Step 2/5: Python\nParsed source data and started computing feature columns."
        )
        messagesBySession[session.id] = [welcome, seedLog1, seedLog2, seedLog3]

        activeProjectID = nil
        activeSessionID = nil
    }


    internal static let codexApprovalPolicyForPermissionChange = "on-request"

    internal static func codexSandbox(for level: SessionPermissionLevel) -> JSONValue {
        let mode: String
        switch level {
        case .default:
            mode = "workspace-write"
        case .full:
            mode = "danger-full-access"
        }
        return .object(["mode": .string(mode)])
    }

    internal static func permissionLevel(forCodexSandbox sandbox: JSONValue?) -> SessionPermissionLevel? {
        guard let sandbox = sandbox?.objectValue else { return nil }
        let rawMode = sandbox["mode"]?.stringValue ?? sandbox["type"]?.stringValue
        guard let mode = normalizedCodexSandboxMode(rawMode) else { return nil }
        return mode == "danger-full-access" ? .full : .default
    }

    internal static func normalizedCodexSandboxMode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let compact = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter(\.isLetter)
        switch compact {
        case "readonly":
            return "read-only"
        case "workspacewrite":
            return "workspace-write"
        case "dangerfullaccess":
            return "danger-full-access"
        default:
            return nil
        }
    }

    internal static func parsePermissionLevel(_ raw: String?) -> SessionPermissionLevel? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "default":
            return .default
        case "full":
            return .full
        default:
            return nil
        }
    }
}
