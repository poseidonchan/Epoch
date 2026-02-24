import Combine
import Foundation

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
    @Published public internal(set) var codexPendingApprovalsBySession: [UUID: [CodexPendingApproval]] = [:]
    @Published public internal(set) var codexPendingPromptBySession: [UUID: CodexPendingPrompt] = [:]
    @Published public internal(set) var codexStatusTextBySession: [UUID: String] = [:]
    @Published public internal(set) var codexTokenUsageBySession: [UUID: CodexTokenUsage] = [:]
    @Published public internal(set) var codexFullAccessBySession: [UUID: Bool] = [:]

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

    @Published public var resourceStatus: ResourceStatus = .placeholder

    @Published public internal(set) var gatewayConnectionState: GatewayConnectionState = .disconnected
    @Published public internal(set) var codexConnectionState: CodexConnectionState = .disconnected
    @Published public var gatewayWSURLString: String = ""
    @Published public var gatewayToken: String = ""
    @Published public var preferredBackendEngine: String = "pi"

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
    internal var codexThreadBySession: [UUID: String] = [:]
    internal var codexSessionByThread: [String: UUID] = [:]

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
        preferredBackendEngine = normalizeBackendEngine(defaults.string(forKey: DefaultsKey.backendEngine)) ?? "pi"
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
        let normalized = normalizeBackendEngine(backendEngine) ?? "pi"
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
            return "pi"
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
        codexPendingApprovalsBySession.removeAll()
        codexPendingPromptBySession.removeAll()
        codexStatusTextBySession.removeAll()
        codexTokenUsageBySession.removeAll()
        codexFullAccessBySession.removeAll()
        codexThreadBySession.removeAll()
        codexSessionByThread.removeAll()
        chatService.sessionHistoryRequestsInFlight.removeAll()
        chatService.sessionHistoryLastFetchedAtBySession.removeAll()
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

                try? await Task.sleep(for: .seconds(5))
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

    private func handleCodexNotification(_ notification: CodexRPCNotification) {
        guard let params = notification.params?.objectValue else { return }
        let threadId = params["threadId"]?.stringValue
        let sessionID = threadId.flatMap { codexSessionByThread[$0] }

        switch notification.method {
        case "turn/started":
            if let sessionID {
                if let turn = params["turn"]?.objectValue,
                   let status = turn["status"]?.stringValue {
                    codexStatusTextBySession[sessionID] = status
                }
            }
        case "turn/completed":
            if let sessionID,
               let turn = params["turn"]?.objectValue,
               let status = turn["status"]?.stringValue {
                codexStatusTextBySession[sessionID] = status
                streamingSessions.remove(sessionID)
            }
        case "turn/plan/updated":
            break
        case "turn/diff/updated":
            break
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
        default:
            if let sessionID, notification.method.hasPrefix("codex/event/"),
               let statusText = extractCodexStatusText(notificationMethod: notification.method, params: params) {
                codexStatusTextBySession[sessionID] = statusText
            }
            break
        }
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
        guard let itemData = try? gatewayJSONEncoder.encode(itemValue),
              let item = try? gatewayJSONDecoder.decode(CodexThreadItem.self, from: itemData)
        else { return }

        var items = codexItemsBySession[sessionID] ?? []
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        codexItemsBySession[sessionID] = items
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

    private func applyCodexTokenUsage(notificationParams params: [String: JSONValue], sessionID: UUID?) {
        guard let sessionID else { return }
        guard let threadId = params["threadId"]?.stringValue else { return }
        guard let tokenUsage = params["tokenUsage"]?.objectValue else { return }

        let contextWindow = tokenUsage["contextWindow"]?.intValue ?? tokenUsage["contextWindowTokens"]?.intValue
        let inputTokens = tokenUsage["inputTokens"]?.intValue ?? tokenUsage["totalInputTokens"]?.intValue
        let outputTokens = tokenUsage["outputTokens"]?.intValue ?? tokenUsage["totalOutputTokens"]?.intValue
        let totalTokens = tokenUsage["totalTokens"]?.intValue ?? inputTokens
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
            model: tokenUsage["model"]?.stringValue ?? tokenUsage["modelId"]?.stringValue
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

    private func sessionProjectID(_ sessionID: UUID) -> UUID? {
        for (projectID, sessions) in sessionsByProject where sessions.contains(where: { $0.id == sessionID }) {
            return projectID
        }
        return activeProjectID
    }

    private func handleCodexServerRequest(_ request: CodexRPCRequest) async {
        guard let params = request.params?.objectValue else {
            try? await codexClient?.respond(
                error: CodexRPCError(code: -32602, message: "Missing params"),
                for: request.id
            )
            return
        }

        let threadId = params["threadId"]?.stringValue ?? ""
        guard let sessionID = codexSessionByThread[threadId] else {
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
        case "item/tool/requestUserInput":
            let prompt = CodexPendingPrompt(
                requestID: request.id,
                sessionID: sessionID,
                threadId: threadId,
                turnId: params["turnId"]?.stringValue,
                prompt: params["prompt"]?.stringValue ?? params["message"]?.stringValue,
                rawParams: request.params
            )
            codexPendingPromptBySession[sessionID] = prompt
        default:
            try? await codexClient?.respond(
                error: CodexRPCError(code: -32601, message: "Unsupported server request: \(request.method)"),
                for: request.id
            )
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

        case let .approvalResolved(planID, decision):
            planService.handleApprovalResolved(planID: planID, decision: decision)

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
        } else {
            codexThreadBySession[session.id] = nil
            if let previousThreadId {
                codexSessionByThread[previousThreadId] = nil
            }
        }
        if let sandbox = session.codexSandbox?.objectValue,
           let mode = sandbox["mode"]?.stringValue {
            codexFullAccessBySession[session.id] = (mode == "danger-full-access")
        } else {
            codexFullAccessBySession[session.id] = false
        }
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
        if let mappedThread = codexThreadBySession[sessionID], !mappedThread.isEmpty {
            return true
        }
        guard let session = sessionRecord(for: sessionID) else { return false }
        if normalizeBackendEngine(session.backendEngine) == "codex-app-server" {
            return true
        }
        if let rawThreadId = session.codexThreadId,
           let threadId = normalizedOptionalString(rawThreadId),
           !threadId.isEmpty {
            return true
        }
        return false
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
            return nil
        }
        return composerService.contextWindowTokens(for: sessionID)
    }

    public func permissionLevel(for sessionID: UUID) -> SessionPermissionLevel {
        composerService.permissionLevel(for: sessionID)
    }

    public func setPermissionLevel(projectID: UUID, sessionID: UUID, level: SessionPermissionLevel) {
        composerService.setPermissionLevel(projectID: projectID, sessionID: sessionID, level: level)
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

    public func codexPendingApprovals(for sessionID: UUID) -> [CodexPendingApproval] {
        codexPendingApprovalsBySession[sessionID] ?? []
    }

    public func codexPendingPrompt(for sessionID: UUID) -> CodexPendingPrompt? {
        codexPendingPromptBySession[sessionID]
    }

    public func codexStatusText(for sessionID: UUID) -> String? {
        codexStatusTextBySession[sessionID]
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
            guard let self, let codexClient = self.codexClient else { return }
            let result = JSONValue.object(["decision": .string(decision)])
            try? await codexClient.respond(result: result, for: requestID)
            var approvals = self.codexPendingApprovalsBySession[sessionID] ?? []
            approvals.removeAll { $0.requestID == requestID }
            self.codexPendingApprovalsBySession[sessionID] = approvals
        }
    }

    public func respondToCodexPrompt(
        sessionID: UUID,
        requestID: CodexRequestID,
        answers: [String: String]
    ) {
        Task { [weak self] in
            guard let self, let codexClient = self.codexClient else { return }
            let payload = JSONValue.object([
                "answers": .object(answers.mapValues { .string($0) }),
            ])
            try? await codexClient.respond(result: payload, for: requestID)
            self.codexPendingPromptBySession[sessionID] = nil
        }
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

    public func retryCodexAgentMessage(
        projectID: UUID,
        sessionID: UUID,
        assistantItemID: String,
        modelIdOverride: String? = nil
    ) {
        chatService.retryCodexAgentMessage(
            projectID: projectID,
            sessionID: sessionID,
            assistantItemID: assistantItemID,
            modelIdOverride: modelIdOverride
        )
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
            openSession(projectID: projectID, sessionID: sessionID)
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
