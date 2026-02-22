import Combine
import Foundation

@MainActor
public final class AppStore: ObservableObject {
    internal enum DefaultsKey {
        static let gatewayDeviceID = "LabOS.gateway.deviceID"
        static let gatewayWSURL = "LabOS.gateway.wsURL"
        static let gatewayToken = "LabOS.gateway.token"
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
    @Published public var gatewayWSURLString: String = ""
    @Published public var gatewayToken: String = ""

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

    private var pendingApprovalsBySession: [UUID: PendingApproval] = [:]
    private var planSessionByPlanID: [UUID: UUID] = [:]
    private struct PendingLocalUserEcho: Sendable {
        var localId: UUID
        var text: String
        var createdAt: Date
        var artifactRefs: [ChatArtifactReference]
        var attachments: [ComposerAttachment]
    }
    enum SessionHistoryRefreshTrigger {
        case interactive
        case prefetch
    }
    private struct GatewayChatSendParams: Codable, Sendable {
        // NOTE: Encode IDs as lowercase strings for compatibility with case-sensitive backends
        // (e.g. SQLite TEXT UUIDs created via uuidv4()).
        var projectId: String
        var sessionId: String
        var text: String
        var overwriteMessageId: String?
        var attachments: [GatewayChatAttachment]?
        var modelId: String?
        var thinkingLevel: ThinkingLevel?
        var planMode: Bool
        var permissionLevel: SessionPermissionLevel
    }

    private struct GatewayChatAttachment: Codable, Sendable {
        var id: String
        var scope: String
        var name: String
        var path: String
        var mimeType: String?
        var inlineDataBase64: String?
        var byteCount: Int?
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

    private struct GatewayUploadResponse: Decodable, Sendable {
        var uploadId: String
        var path: String
    }
    private var pendingLocalUserEchosBySession: [UUID: [PendingLocalUserEcho]] = [:]
    internal var artifactContentCache: [String: String] = [:]
    internal var artifactDataCache: [String: Data] = [:]
    private let backend: BackendClient
    internal let defaults: UserDefaults
    internal var gatewayClient: GatewayClient?
    private var gatewayEventsTask: Task<Void, Never>?
    private var gatewayStateCancellable: AnyCancellable?
    private var gatewayEnsureConnectedTask: Task<Bool, Never>?
    internal var gatewayDeviceID: UUID = UUID()
    private var resourcesPollTask: Task<Void, Never>?
    private var observedTerminalRunIDs: Set<UUID> = []
    private var sessionHistoryRequestsInFlight: Set<UUID> = []
    private var sessionHistoryLastFetchedAtBySession: [UUID: Date] = [:]
    private var sessionHistoryPrefetchTasksByProject: [UUID: Task<Void, Never>] = [:]
    private let sessionHistoryPrefetchCooldown: TimeInterval = 45
    private let sessionHistoryInteractiveFreshnessWindow: TimeInterval = 8

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

        guard isGatewayConnected else { return }

        lastGatewayErrorMessage = nil
        await composerService.refreshModelsFromGateway()
        await refreshProjectsFromGateway()
        composerService.pushHpcPreferencesToGateway()
        startGatewayEventLoop()
        startResourcePolling()
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
        for (_, task) in sessionHistoryPrefetchTasksByProject {
            task.cancel()
        }
        sessionHistoryPrefetchTasksByProject.removeAll()
        gatewayEventsTask?.cancel()
        gatewayEventsTask = nil
        gatewayStateCancellable?.cancel()
        gatewayStateCancellable = nil
        resourcesPollTask?.cancel()
        resourcesPollTask = nil
        gatewayClient?.disconnect()
        gatewayClient = nil
        gatewayConnectionState = .disconnected
        pendingApprovalsBySession.removeAll()
        planSessionByPlanID.removeAll()
        livePlanBySession.removeAll()
        liveAgentEventsBySession.removeAll()
        activeInlineProcessBySession.removeAll()
        persistedProcessSummaryByMessageID.removeAll()
        planModeEnabledBySession.removeAll()
        selectedModelIdBySession.removeAll()
        selectedThinkingLevelBySession.removeAll()
        streamingSessions.removeAll()
        streamingAssistantMessageIDBySession.removeAll()
        sessionHistoryRequestsInFlight.removeAll()
        sessionHistoryLastFetchedAtBySession.removeAll()
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

    private func gatewayHTTPBaseURL() -> URL? {
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

    private func refreshProjectsFromGateway() async {
        guard let gatewayClient else { return }
        struct EmptyParams: Codable, Sendable {}
        do {
            let res = try await gatewayClient.request(method: "projects.list", params: EmptyParams())
            let projects: [Project] = try decodeGatewayPayload(res.payload, key: "projects")

            let sorted = projects.sorted { $0.updatedAt > $1.updatedAt }
            let projectIDs = Set(sorted.map(\.id))
            self.projects = sorted

            // Keep existing loaded state to avoid visible "flash back" resets while syncing.
            // Only prune caches for projects that no longer exist remotely.
            self.sessionsByProject = self.sessionsByProject.filter { projectIDs.contains($0.key) }
            self.artifactsByProject = self.artifactsByProject.filter { projectIDs.contains($0.key) }
            self.runsByProject = self.runsByProject.filter { projectIDs.contains($0.key) }
            for (prefetchProjectID, task) in self.sessionHistoryPrefetchTasksByProject where !projectIDs.contains(prefetchProjectID) {
                task.cancel()
                self.sessionHistoryPrefetchTasksByProject[prefetchProjectID] = nil
            }
            let validSessionIDs = Set(self.sessionsByProject.values.flatMap { $0.map(\.id) })
            self.sessionHistoryRequestsInFlight = self.sessionHistoryRequestsInFlight.filter { validSessionIDs.contains($0) }
            self.sessionHistoryLastFetchedAtBySession = self.sessionHistoryLastFetchedAtBySession.filter { validSessionIDs.contains($0.key) }

            if let activeProjectID, !projectIDs.contains(activeProjectID) {
                self.activeProjectID = nil
                self.activeSessionID = nil
            }
        } catch {
            lastGatewayErrorMessage = error.localizedDescription
            gatewayConnectionState = .failed(message: error.localizedDescription)
        }
    }

    private func refreshProjectFromGateway(projectID: UUID) async {
        guard let gatewayClient else { return }

        struct SessionsListParams: Codable, Sendable {
            var projectId: String
            var includeArchived: Bool
        }
        struct ArtifactsListParams: Codable, Sendable {
            var projectId: String
            var prefix: String?
        }
        struct RunsListParams: Codable, Sendable {
            var projectId: String
        }

        do {
            let sessionsRes = try await gatewayClient.request(
                method: "sessions.list",
                params: SessionsListParams(projectId: Self.gatewayID(projectID), includeArchived: true)
            )
            let sessions: [Session] = try decodeGatewayPayload(sessionsRes.payload, key: "sessions")
            sessionsByProject[projectID] = sessions
            for session in sessions {
                ensureComposerPrefs(sessionID: session.id)
            }

            let artifactsRes = try await gatewayClient.request(
                method: "artifacts.list",
                params: ArtifactsListParams(projectId: Self.gatewayID(projectID), prefix: nil)
            )
            let artifacts: [Artifact] = try decodeGatewayPayload(artifactsRes.payload, key: "artifacts")
            artifactsByProject[projectID] = artifacts

            let runsRes = try await gatewayClient.request(method: "runs.list", params: RunsListParams(projectId: Self.gatewayID(projectID)))
            let runs: [RunRecord] = try decodeGatewayPayload(runsRes.payload, key: "runs")
            let existing = Dictionary(uniqueKeysWithValues: (runsByProject[projectID] ?? []).map { ($0.id, $0) })
            let merged = runs.map { remote in
                var updated = remote
                if let local = existing[remote.id] {
                    if updated.activity.isEmpty, !local.activity.isEmpty {
                        updated.activity = local.activity
                    }
                    if updated.stepDetails.isEmpty, !local.stepDetails.isEmpty {
                        updated.stepDetails = local.stepDetails
                    }
                }
                return updated
            }
            runsByProject[projectID] = merged
        } catch {
            gatewayConnectionState = .failed(message: error.localizedDescription)
        }
    }

    private func refreshSessionHistoryFromGateway(
        projectID: UUID,
        sessionID: UUID,
        trigger: SessionHistoryRefreshTrigger = .interactive
    ) async {
        guard let gatewayClient else { return }
        let now = Date()
        let hasLocalMessages = !(messagesBySession[sessionID]?.isEmpty ?? true)
        if Self.shouldSkipSessionHistoryRefresh(
            trigger: trigger,
            hasInFlightRequest: sessionHistoryRequestsInFlight.contains(sessionID),
            hasLocalMessages: hasLocalMessages,
            lastFetchedAt: sessionHistoryLastFetchedAtBySession[sessionID],
            now: now,
            prefetchCooldown: sessionHistoryPrefetchCooldown,
            interactiveFreshnessWindow: sessionHistoryInteractiveFreshnessWindow
        ) {
            return
        }

        sessionHistoryRequestsInFlight.insert(sessionID)
        defer { sessionHistoryRequestsInFlight.remove(sessionID) }

        struct HistoryParams: Codable, Sendable {
            var projectId: String
            var sessionId: String
            var beforeTs: Date?
            var limit: Int
        }
        struct ContextParams: Codable, Sendable {
            var projectId: String
            var sessionId: String
        }

        do {
            let res = try await gatewayClient.request(
                method: "chat.history",
                params: HistoryParams(projectId: Self.gatewayID(projectID), sessionId: Self.gatewayID(sessionID), beforeTs: nil, limit: 200)
            )
            let messages: [ChatMessage] = try decodeGatewayPayload(res.payload, key: "messages")
            applySessionHistorySnapshot(
                projectID: projectID,
                sessionID: sessionID,
                messages: messages,
                fetchedAt: now
            )

            if let contextRes = try? await gatewayClient.request(
                method: "sessions.context.get",
                params: ContextParams(projectId: Self.gatewayID(projectID), sessionId: Self.gatewayID(sessionID))
            ) {
                if let context: SessionContextState = try? decodeGatewayPayload(contextRes.payload, key: "context") {
                    sessionContextBySession[sessionID] = context
                    if let level = Self.parsePermissionLevel(context.permissionLevel) {
                        permissionLevelBySession[sessionID] = level
                    }
                }
            }
        } catch {
            gatewayConnectionState = .failed(message: error.localizedDescription)
        }
    }

    func applySessionHistorySnapshot(
        projectID: UUID,
        sessionID: UUID,
        messages: [ChatMessage],
        fetchedAt: Date
    ) {
        let sortedMessages = messages.sorted(by: Self.messageDisplayOrder)
        messagesBySession[sessionID] = sortedMessages
        pruneAttachmentPayloads(for: sessionID, keptMessageIDs: Set(sortedMessages.map(\.id)))
        sessionHistoryLastFetchedAtBySession[sessionID] = fetchedAt
        reconcileInlineProcessAfterHistorySync(projectID: projectID, sessionID: sessionID, messages: sortedMessages)
    }

    private func reconcileInlineProcessAfterHistorySync(
        projectID: UUID,
        sessionID: UUID,
        messages: [ChatMessage]
    ) {
        guard activeInlineProcessBySession[sessionID] != nil else { return }
        let hasPendingLocalEcho = !(pendingLocalUserEchosBySession[sessionID]?.isEmpty ?? true)
        guard !hasActiveRun(projectID: projectID, sessionID: sessionID) else { return }

        if let assistantMessageID = Self.latestAssistantReplyID(in: messages) {
            if hasPendingLocalEcho {
                pendingLocalUserEchosBySession[sessionID] = nil
            }
            if var process = activeInlineProcessBySession[sessionID] {
                let currentlyBoundAssistantID = process.assistantMessageID
                let isBoundAssistantStillPresent = currentlyBoundAssistantID.map { currentID in
                    messages.contains { $0.id == currentID }
                } ?? false
                if !isBoundAssistantStillPresent {
                    process.assistantMessageID = assistantMessageID
                    activeInlineProcessBySession[sessionID] = process
                }
            }
            finalizeInlineProcess(
                sessionID: sessionID,
                failed: false,
                assistantMessageIDFallback: assistantMessageID
            )
            streamingAssistantMessageIDBySession[sessionID] = nil
            streamingSessions.remove(sessionID)
            clearLiveAgentEvents(sessionID: sessionID)
            return
        }

        if hasPendingLocalEcho {
            return
        }

        if let lastMessage = messages.last, lastMessage.role == .user {
            return
        }

        streamingAssistantMessageIDBySession[sessionID] = nil
        streamingSessions.remove(sessionID)
        activeInlineProcessBySession[sessionID] = nil
        clearLiveAgentEvents(sessionID: sessionID)
    }

    private func hasActiveRun(projectID: UUID, sessionID: UUID) -> Bool {
        (runsByProject[projectID] ?? []).contains { run in
            run.sessionID == sessionID && (run.status == .queued || run.status == .running)
        }
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

    private func scheduleSessionHistoryPrefetch(projectID: UUID) {
        guard isGatewayConnected else { return }
        let loadedSessionIDs = Set(
            messagesBySession.compactMap { sessionID, messages in
                messages.isEmpty ? nil : sessionID
            }
        )
        let candidates = Self.sessionHistoryPrefetchCandidates(
            sessions: sessions(for: projectID),
            activeSessionID: activeSessionID,
            loadedMessageSessionIDs: loadedSessionIDs,
            inFlightSessionIDs: sessionHistoryRequestsInFlight,
            lastFetchedAtBySession: sessionHistoryLastFetchedAtBySession,
            now: .now,
            cooldown: sessionHistoryPrefetchCooldown
        )
        guard !candidates.isEmpty else { return }
        let targetSessionIDs = Array(candidates.prefix(8))

        sessionHistoryPrefetchTasksByProject[projectID]?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.sessionHistoryPrefetchTasksByProject[projectID] = nil }
            for sessionID in targetSessionIDs {
                guard !Task.isCancelled else { return }
                await self.refreshSessionHistoryFromGateway(projectID: projectID, sessionID: sessionID, trigger: .prefetch)
            }
        }
        sessionHistoryPrefetchTasksByProject[projectID] = task
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

        case let .chatMessageCreated(projectID, sessionID, message):
            _ = projectID
            applyRemoteMessage(sessionID: sessionID, message: message)

        case let .assistantDelta(payload):
            applyAssistantDelta(payload)

        case let .toolEvent(payload):
            applyToolEvent(payload)

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
	            let pending = PendingApproval(
	                planId: payload.planId,
                projectId: payload.projectId,
                sessionId: payload.sessionId,
                agentRunId: payload.agentRunId,
                plan: payload.plan,
                required: payload.required,
                judgment: payload.judgment
            )
            pendingApprovalsBySession[payload.sessionId] = pending
            planSessionByPlanID[payload.planId] = payload.sessionId

        case let .approvalResolved(planID, _):
            if let sessionID = planSessionByPlanID[planID] {
                pendingApprovalsBySession[sessionID] = nil
            }
            planSessionByPlanID[planID] = nil

        case let .runsUpdated(projectID, run, change: _):
            upsertRun(projectID: projectID, run: run)

        case let .runsLogDelta(payload):
            applyRunLogDelta(payload)

        case let .artifactsUpdated(projectID, artifact, change: _):
            upsertArtifact(projectID: projectID, artifact: artifact)

        case let .lifecycle(payload):
            applyLifecycle(payload)
        }
    }

    private func upsertProject(_ project: Project) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        } else {
            projects.insert(project, at: 0)
        }
    }

    private func upsertSession(_ session: Session) {
        var sessions = sessionsByProject[session.projectID, default: []]
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessionsByProject[session.projectID] = sessions
        ensureComposerPrefs(sessionID: session.id)
    }

    private func upsertRun(projectID: UUID, run: RunRecord) {
        var runs = runsByProject[projectID, default: []]
        var previousRun: RunRecord?
        var updatedRun = run
        if let idx = runs.firstIndex(where: { $0.id == run.id }) {
            var merged = run
            let existing = runs[idx]
            previousRun = existing
            if merged.activity.isEmpty, !existing.activity.isEmpty {
                merged.activity = existing.activity
            }
            if merged.stepDetails.isEmpty, !existing.stepDetails.isEmpty {
                merged.stepDetails = existing.stepDetails
            }
            runs[idx] = merged
            updatedRun = merged
        } else {
            runs.insert(run, at: 0)
        }
        runsByProject[projectID] = runs.sorted { $0.initiatedAt > $1.initiatedAt }
        if let previousRun {
            emitRunCompletionSignalIfNeeded(projectID: projectID, previousRun: previousRun, updatedRun: updatedRun)
        }
    }

    private func upsertArtifact(projectID: UUID, artifact: Artifact) {
        var artifacts = artifactsByProject[projectID, default: []]
        if let idx = artifacts.firstIndex(where: { $0.path == artifact.path }) {
            artifacts[idx] = artifact
        } else {
            artifacts.append(artifact)
        }
        artifactsByProject[projectID] = artifacts.sorted { $0.path < $1.path }

        let key = "\(projectID.uuidString)::\(artifact.path)"
        artifactContentCache[key] = nil
        artifactDataCache[key] = nil
    }

    private func applyRemoteMessage(sessionID: UUID, message: ChatMessage) {
        var messages = messagesBySession[sessionID, default: []]
        var resolvedMessage = message

        // If we optimistically inserted a local user message, replace it with the server's
        // canonical message to avoid "first message swallowed" UX and prevent duplicates.
        if resolvedMessage.role == .user {
            let normalized = resolvedMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty, var pending = pendingLocalUserEchosBySession[sessionID] {
                let matchIdx =
                    pending.firstIndex(where: { $0.text == normalized && abs($0.createdAt.timeIntervalSince(resolvedMessage.createdAt)) < 30 })
                    ?? pending.firstIndex(where: { $0.text == normalized })
                if let matchIdx {
                    let pendingEcho = pending[matchIdx]
                    resolvedMessage.artifactRefs = Self.mergeArtifactRefsPreservingInlineForGatewayEcho(
                        remoteArtifactRefs: resolvedMessage.artifactRefs,
                        localArtifactRefs: pendingEcho.artifactRefs
                    )
                    let localId = pendingEcho.localId
                    let transferredAttachments = pendingEcho.attachments.isEmpty
                        ? attachmentPayload(for: sessionID, messageID: localId)
                        : pendingEcho.attachments
                    if !transferredAttachments.isEmpty {
                        setAttachmentPayload(
                            for: sessionID,
                            messageID: resolvedMessage.id,
                            attachments: transferredAttachments
                        )
                    }
                    if localId != resolvedMessage.id {
                        setAttachmentPayload(for: sessionID, messageID: localId, attachments: [])
                    }
                    messages.removeAll { $0.id == localId }
                    pending.remove(at: matchIdx)
                    pendingLocalUserEchosBySession[sessionID] = pending.isEmpty ? nil : pending
                }
            }
        }

        if let idx = messages.firstIndex(where: { $0.id == resolvedMessage.id }) {
            messages[idx] = resolvedMessage
        } else {
            messages.append(resolvedMessage)
        }
        messagesBySession[sessionID] = messages.sorted(by: Self.messageDisplayOrder)

        if resolvedMessage.role == .assistant,
           var process = activeInlineProcessBySession[sessionID],
           process.assistantMessageID == nil {
            process.assistantMessageID = resolvedMessage.id
            activeInlineProcessBySession[sessionID] = process
        }

        if resolvedMessage.role == .assistant {
            streamingSessions.remove(sessionID)
            streamingAssistantMessageIDBySession[sessionID] = nil
            finalizeInlineProcess(sessionID: sessionID, failed: false, assistantMessageIDFallback: resolvedMessage.id)
            clearLiveAgentEvents(sessionID: sessionID)
        }
    }

    private func applyAssistantDelta(_ payload: AssistantDeltaPayload) {
        let sessionID = payload.sessionId
        var messages = messagesBySession[sessionID, default: []]

        streamingSessions.insert(sessionID)
        streamingAssistantMessageIDBySession[sessionID] = payload.messageId
        transitionInlineProcessToResponding(sessionID: sessionID, messageID: payload.messageId)

        if let idx = messages.firstIndex(where: { $0.id == payload.messageId }) {
            messages[idx].text += payload.delta
        } else {
            var msg = ChatMessage(
                id: payload.messageId,
                sessionID: sessionID,
                role: .assistant,
                text: payload.delta,
                createdAt: .now
            )
            msg.proposedPlan = nil
            messages.append(msg)
        }

        messagesBySession[sessionID] = messages.sorted(by: Self.messageDisplayOrder)
    }

    private func applyToolEvent(_ payload: ToolEventPayload) {
        let phase = payload.phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if shouldIgnoreLateToolEvent(payload: payload, phase: phase) {
            return
        }

        let summary = payload.summary.isEmpty ? "\(payload.tool) · \(payload.phase)" : payload.summary
        let detail = formattedJSONDetail(payload.detail)
        if let runID = payload.runId {
            mutateRun(projectID: payload.projectId, runID: runID) { run in
                run.activity.append(RunActionEvent(type: .toolCall, summary: summary, detail: detail))
            }
        }

        applyInlineToolEvent(payload, fallbackSummary: summary)

        let liveSummary = switch phase {
        case "start":
            "Calling tool: \(payload.tool)"
        case "update":
            "Tool update: \(payload.tool)"
        case "end":
            "Tool finished: \(payload.tool)"
        case "error":
            "Tool failed: \(payload.tool)"
        default:
            "Tool event: \(payload.tool)"
        }

        let liveDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? summary : detail
        appendLiveAgentEvent(
            sessionID: payload.sessionId,
            type: .toolCall,
            summary: liveSummary,
            detail: liveDetail
        )
        streamingSessions.insert(payload.sessionId)
    }

    private func appendLiveAgentEvent(
        sessionID: UUID,
        type: AgentLiveEventType,
        summary: String,
        detail: String? = nil
    ) {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSummary.isEmpty else { return }

        let normalizedDetail = detail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var events = liveAgentEventsBySession[sessionID] ?? []
        if let last = events.last,
           last.type == type,
           last.summary == trimmedSummary,
           last.detail == normalizedDetail {
            return
        }

        events.append(
            AgentLiveEvent(
                sessionID: sessionID,
                type: type,
                summary: trimmedSummary,
                detail: normalizedDetail
            )
        )

        if events.count > 12 {
            events.removeFirst(events.count - 12)
        }
        liveAgentEventsBySession[sessionID] = events
    }

    private func shouldIgnoreLateToolEvent(payload: ToolEventPayload, phase: String) -> Bool {
        guard phase == "start" || phase == "update" || phase == "end" || phase == "error" else {
            return false
        }
        guard activeInlineProcessBySession[payload.sessionId] == nil else {
            return false
        }
        guard pendingLocalUserEchosBySession[payload.sessionId]?.isEmpty ?? true else {
            return false
        }
        guard !hasActiveRun(projectID: payload.projectId, sessionID: payload.sessionId) else {
            return false
        }

        let latestTurnRole = messages(for: payload.sessionId)
            .last(where: { $0.role == .user || $0.role == .assistant })?
            .role
        return latestTurnRole == .assistant
    }

    private func clearLiveAgentEvents(sessionID: UUID) {
        liveAgentEventsBySession[sessionID] = []
    }

    private func formattedJSONDetail(_ detail: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(detail),
              let text = String(data: data, encoding: .utf8)
        else {
            return String(describing: detail)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 1_500 {
            return String(trimmed.prefix(1_500)) + "\n…"
        }
        return trimmed
    }

    private func applyLifecycle(_ payload: LifecyclePayload) {
        let phase = payload.phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch phase {
        case "start":
            streamingSessions.insert(payload.sessionId)
            beginInlineProcess(sessionID: payload.sessionId, runID: payload.agentRunId)
        case "end", "error":
            streamingSessions.remove(payload.sessionId)
            streamingAssistantMessageIDBySession[payload.sessionId] = nil
            if phase == "error", let err = payload.error {
                let text = "Run failed (\(err.code)): \(err.message)"
                messagesBySession[payload.sessionId, default: []].append(
                    ChatMessage(sessionID: payload.sessionId, role: .system, text: text)
                )
            }
            finalizeInlineProcess(sessionID: payload.sessionId, failed: phase == "error")
            clearLiveAgentEvents(sessionID: payload.sessionId)
        default:
            break
        }
    }

    private func beginInlineProcess(sessionID: UUID, runID: UUID) {
        activeInlineProcessBySession[sessionID] = ActiveInlineProcess(
            sessionID: sessionID,
            agentRunID: runID,
            assistantMessageID: nil,
            phase: .thinking,
            activeLine: nil,
            entries: [],
            familyCounts: [:]
        )
    }

    private func transitionInlineProcessToResponding(sessionID: UUID, messageID: UUID) {
        guard var process = activeInlineProcessBySession[sessionID] else { return }
        if process.assistantMessageID == nil {
            process.assistantMessageID = messageID
        }
        process.phase = .responding
        process.activeLine = nil
        activeInlineProcessBySession[sessionID] = process
    }

    private func applyInlineToolEvent(_ payload: ToolEventPayload, fallbackSummary: String) {
        let phase = payload.phase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var process = activeInlineProcessBySession[payload.sessionId]
            ?? ActiveInlineProcess(
                sessionID: payload.sessionId,
                agentRunID: payload.agentRunId,
                phase: .thinking,
                activeLine: nil,
                entries: [],
                familyCounts: [:]
            )

        let family = toolActionFamily(tool: payload.tool, summary: fallbackSummary)
        let activeText = activeToolPhrase(family: family, fallback: fallbackSummary)
        let completedText = completedToolPhrase(family: family, fallback: fallbackSummary)

        switch phase {
        case "start", "update":
            if let idx = process.entries.lastIndex(where: {
                $0.toolCallID == payload.toolCallId && $0.state == .active
            }) {
                process.entries[idx].family = family
                process.entries[idx].activeText = activeText
                process.entries[idx].completedText = completedText
            } else {
                process.entries.append(
                    ProcessEntry(
                        toolCallID: payload.toolCallId,
                        family: family,
                        activeText: activeText,
                        completedText: completedText,
                        state: .active
                    )
                )
            }
            process.phase = .toolCalling
            process.activeLine = activeText
        case "end":
            if let idx = process.entries.lastIndex(where: {
                $0.toolCallID == payload.toolCallId && $0.state == .active
            }) {
                process.entries[idx].state = .completed
                process.entries[idx].completedText = completedText
                process.familyCounts[family, default: 0] += 1
            } else {
                process.entries.append(
                    ProcessEntry(
                        toolCallID: payload.toolCallId,
                        family: family,
                        activeText: activeText,
                        completedText: completedText,
                        state: .completed
                    )
                )
                process.familyCounts[family, default: 0] += 1
            }

            if process.assistantMessageID == nil {
                process.phase = .thinking
                process.activeLine = nil
            } else {
                process.phase = .responding
                process.activeLine = nil
            }
        case "error":
            if let idx = process.entries.lastIndex(where: {
                $0.toolCallID == payload.toolCallId && $0.state == .active
            }) {
                process.entries[idx].state = .failed
                process.entries[idx].completedText = completedText
            } else {
                process.entries.append(
                    ProcessEntry(
                        toolCallID: payload.toolCallId,
                        family: family,
                        activeText: activeText,
                        completedText: completedText,
                        state: .failed
                    )
                )
            }
            if process.assistantMessageID == nil {
                process.phase = .thinking
                process.activeLine = nil
            } else {
                process.phase = .responding
                process.activeLine = nil
            }
        default:
            break
        }

        activeInlineProcessBySession[payload.sessionId] = process
    }

    private func finalizeInlineProcess(
        sessionID: UUID,
        failed: Bool,
        assistantMessageIDFallback: UUID? = nil
    ) {
        guard var process = activeInlineProcessBySession[sessionID] else { return }
        if process.assistantMessageID == nil, let assistantMessageIDFallback {
            process.assistantMessageID = assistantMessageIDFallback
        }
        process.phase = failed ? .failed : .completed

        if let assistantMessageID = process.assistantMessageID,
           !process.entries.isEmpty {
            let headline = summaryHeadline(from: process.familyCounts, fallbackEntryCount: process.entries.count)
            persistedProcessSummaryByMessageID[assistantMessageID] = AssistantProcessSummary(
                sessionID: sessionID,
                assistantMessageID: assistantMessageID,
                headline: headline,
                entries: process.entries,
                familyCounts: process.familyCounts
            )
        }

        activeInlineProcessBySession[sessionID] = nil
    }

    private func summaryHeadline(
        from familyCounts: [ProcessActionFamily: Int],
        fallbackEntryCount: Int
    ) -> String {
        let displayOrder: [ProcessActionFamily] = [.search, .list, .read, .write, .exec, .other]
        let parts = displayOrder.compactMap { family -> String? in
            guard let count = familyCounts[family], count > 0 else { return nil }
            return "\(count) \(label(for: family, count: count))"
        }
        if parts.isEmpty {
            return "Explored \(fallbackEntryCount) steps"
        }
        return "Explored " + parts.joined(separator: ", ")
    }

    private func label(for family: ProcessActionFamily, count: Int) -> String {
        switch family {
        case .search:
            return count == 1 ? "search" : "searches"
        case .list:
            return count == 1 ? "list" : "lists"
        case .read:
            return count == 1 ? "read" : "reads"
        case .write:
            return count == 1 ? "write" : "writes"
        case .exec:
            return count == 1 ? "command" : "commands"
        case .other:
            return count == 1 ? "step" : "steps"
        }
    }

    private func toolActionFamily(tool: String, summary: String) -> ProcessActionFamily {
        let text = "\(tool) \(summary)".lowercased()
        if text.contains("search") || text.contains("query") || text.contains("find") {
            return .search
        }
        if text.contains("list") || text.contains("ls") || text.contains("scan") {
            return .list
        }
        if text.contains("read") || text.contains("open") || text.contains("cat") {
            return .read
        }
        if text.contains("write") || text.contains("patch") || text.contains("edit") {
            return .write
        }
        if text.contains("exec") || text.contains("shell") || text.contains("python") || text.contains("command") {
            return .exec
        }
        return .other
    }

    private func activeToolPhrase(family: ProcessActionFamily, fallback: String) -> String {
        switch family {
        case .search:
            return "Searching..."
        case .list:
            return "Listing files..."
        case .read:
            return "Reading files..."
        case .write:
            return "Writing changes..."
        case .exec:
            return "Running command..."
        case .other:
            return normalizeActiveFallback(fallback)
        }
    }

    private func completedToolPhrase(family: ProcessActionFamily, fallback: String) -> String {
        switch family {
        case .search:
            return "Searched ..."
        case .list:
            return "Listed files ..."
        case .read:
            return "Read files ..."
        case .write:
            return "Wrote changes ..."
        case .exec:
            return "Ran command ..."
        case .other:
            return normalizeCompletedFallback(fallback)
        }
    }

    private func normalizeActiveFallback(_ fallback: String) -> String {
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Exploring..." }
        if trimmed.hasSuffix("...") { return trimmed }
        return trimmed + "..."
    }

    private func normalizeCompletedFallback(_ fallback: String) -> String {
        let active = normalizeActiveFallback(fallback)
        let lower = active.lowercased()
        if lower.hasSuffix("ing..."), active.count > 6 {
            let stem = String(active.dropLast(6))
            return stem + "ed ..."
        }
        if active.hasSuffix("..."), active.count > 3 {
            let stem = String(active.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stem.isEmpty {
                return "Completed \(stem) ..."
            }
        }
        return "Completed ..."
    }

    private func applyRunLogDelta(_ payload: RunLogDeltaPayload) {
        guard var runs = runsByProject[payload.projectId] else { return }
        guard let idx = runs.firstIndex(where: { $0.id == payload.runId }) else { return }
        let trimmed = payload.delta.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            runs[idx].logSnippet = trimmed
        }
        runsByProject[payload.projectId] = runs
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
        composerService.contextRemainingFraction(for: sessionID)
    }

    public func contextWindowTokens(for sessionID: UUID) -> Int? {
        composerService.contextWindowTokens(for: sessionID)
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
        let sessions = sessionsByProject[projectID] ?? []
        return sessions.sorted { lhs, rhs in
            if lhs.lifecycle != rhs.lifecycle {
                return lhs.lifecycle == .active
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    public func artifacts(for projectID: UUID) -> [Artifact] {
        (artifactsByProject[projectID] ?? []).sorted { $0.path < $1.path }
    }

    public func uploadedArtifacts(for projectID: UUID) -> [Artifact] {
        artifacts(for: projectID).filter { $0.origin == .userUpload }
    }

    public func generatedArtifacts(for projectID: UUID) -> [Artifact] {
        artifacts(for: projectID).filter { $0.origin == .generated }
    }

    public func runs(for projectID: UUID) -> [RunRecord] {
        (runsByProject[projectID] ?? []).sorted { $0.initiatedAt > $1.initiatedAt }
    }

    public func run(runID: UUID) -> RunRecord? {
        for runs in runsByProject.values {
            if let matched = runs.first(where: { $0.id == runID }) {
                return matched
            }
        }
        return nil
    }

    public func messages(for sessionID: UUID) -> [ChatMessage] {
        (messagesBySession[sessionID] ?? []).sorted(by: Self.messageDisplayOrder)
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

    private func attachmentPayload(for sessionID: UUID, messageID: UUID) -> [ComposerAttachment] {
        composerService.attachmentPayload(for: sessionID, messageID: messageID)
    }

    private func attachmentsFromArtifactRefs(_ refs: [ChatArtifactReference]) -> [ComposerAttachment] {
        composerService.attachmentsFromArtifactRefs(refs)
    }

    private func setAttachmentPayload(
        for sessionID: UUID,
        messageID: UUID,
        attachments: [ComposerAttachment]
    ) {
        composerService.setAttachmentPayload(for: sessionID, messageID: messageID, attachments: attachments)
    }

    private func pruneAttachmentPayloads(for sessionID: UUID, keptMessageIDs: Set<UUID>) {
        composerService.pruneAttachmentPayloads(for: sessionID, keptMessageIDs: keptMessageIDs)
    }

    private static func messageDisplayOrder(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
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
        (liveAgentEventsBySession[sessionID] ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    public func activeInlineProcess(for sessionID: UUID) -> ActiveInlineProcess? {
        activeInlineProcessBySession[sessionID]
    }

    public func pendingInlineProcess(for sessionID: UUID) -> ActiveInlineProcess? {
        guard let process = activeInlineProcessBySession[sessionID],
              process.assistantMessageID == nil
        else { return nil }
        return process
    }

    public func activeInlineProcess(for sessionID: UUID, assistantMessageID: UUID) -> ActiveInlineProcess? {
        guard let process = activeInlineProcessBySession[sessionID],
              process.assistantMessageID == assistantMessageID
        else { return nil }
        return process
    }

    public func persistedProcessSummary(for assistantMessageID: UUID) -> AssistantProcessSummary? {
        persistedProcessSummaryByMessageID[assistantMessageID]
    }

    private func retrySource(for messageID: UUID, in sessionID: UUID) -> (text: String, userMessageID: UUID?)? {
        let sessionMessages = messages(for: sessionID)
        guard let index = sessionMessages.firstIndex(where: { $0.id == messageID }) else { return nil }
        let message = sessionMessages[index]

        let source: String
        let sourceUserMessageID: UUID?
        switch message.role {
        case .user:
            source = message.text
            sourceUserMessageID = nil
        case .assistant:
            let previous = sessionMessages[..<index].last(where: { $0.role == .user })
            source = previous?.text ?? message.text
            sourceUserMessageID = previous?.id
        case .tool, .system:
            source = message.text
            sourceUserMessageID = nil
        }

        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed, sourceUserMessageID)
    }

    public func retrySourceText(for messageID: UUID, in sessionID: UUID) -> String? {
        retrySource(for: messageID, in: sessionID)?.text
    }

    public func retryMessage(
        projectID: UUID,
        sessionID: UUID,
        fromMessageID messageID: UUID,
        modelIdOverride: String? = nil
    ) {
        if let modelIdOverride {
            let trimmed = modelIdOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                setSelectedModelId(for: sessionID, modelId: trimmed)
            }
        }

        guard let source = retrySource(for: messageID, in: sessionID) else { return }
        if let userMessageID = source.userMessageID {
            overwriteUserMessage(
                projectID: projectID,
                sessionID: sessionID,
                messageID: userMessageID,
                text: source.text
            )
            return
        }
        sendMessage(projectID: projectID, sessionID: sessionID, text: source.text)
    }

    public func overwriteUserMessage(
        projectID: UUID,
        sessionID: UUID,
        messageID: UUID,
        text: String
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var messages = messages(for: sessionID)
        guard let editIndex = messages.firstIndex(where: { $0.id == messageID }) else { return }
        guard messages[editIndex].role == .user else { return }
        let existingArtifactRefs = messages[editIndex].artifactRefs
        let existingAttachments = attachmentPayload(for: sessionID, messageID: messageID)
        let effectiveAttachments = existingAttachments.isEmpty ? attachmentsFromArtifactRefs(existingArtifactRefs) : existingAttachments

        messages[editIndex].text = trimmed
        messages[editIndex].artifactRefs = existingArtifactRefs
        messages[editIndex].proposedPlan = nil

        let keptMessages = Array(messages.prefix(editIndex + 1))
        let keptIDs = Set(keptMessages.map(\.id))
        messagesBySession[sessionID] = keptMessages
        pruneAttachmentPayloads(for: sessionID, keptMessageIDs: keptIDs)
        setAttachmentPayload(for: sessionID, messageID: messageID, attachments: effectiveAttachments)
        persistedProcessSummaryByMessageID = persistedProcessSummaryByMessageID.filter { summary in
            if summary.value.sessionID != sessionID {
                return true
            }
            return keptIDs.contains(summary.key)
        }

        pendingApprovalsBySession[sessionID] = nil
        livePlanBySession[sessionID] = nil
        activeInlineProcessBySession[sessionID] = nil
        clearLiveAgentEvents(sessionID: sessionID)
        for (planID, mappedSessionID) in planSessionByPlanID where mappedSessionID == sessionID {
            planSessionByPlanID[planID] = nil
        }
        streamingSessions.remove(sessionID)
        streamingAssistantMessageIDBySession[sessionID] = nil

        var pendingEchos = pendingLocalUserEchosBySession[sessionID] ?? []
        pendingEchos.removeAll { !keptIDs.contains($0.localId) }
        if isGatewayConfigured {
            pendingEchos.removeAll { $0.localId == messageID }
            pendingEchos.append(
                PendingLocalUserEcho(
                    localId: messageID,
                    text: trimmed,
                    createdAt: .now,
                    artifactRefs: existingArtifactRefs,
                    attachments: effectiveAttachments
                )
            )
        }
        pendingLocalUserEchosBySession[sessionID] = pendingEchos.isEmpty ? nil : pendingEchos

        if isGatewayConfigured {
            sendGatewayChatMessage(
                projectID: projectID,
                sessionID: sessionID,
                text: trimmed,
                attachmentRefs: existingArtifactRefs,
                attachments: effectiveAttachments,
                overwriteMessageID: messageID
            )
            return
        }

        let existingArtifacts = artifactsByProject[projectID] ?? []
        Task { [weak self] in
            guard let self else { return }
            let response = await backend.generateAssistantResponse(
                projectID: projectID,
                sessionID: sessionID,
                userText: trimmed,
                existingArtifacts: existingArtifacts
            )
            self.applyAssistantResponse(projectID: projectID, sessionID: sessionID, response: response)
        }
    }

    @discardableResult
    public func branchFromMessage(
        projectID: UUID,
        sessionID: UUID,
        fromMessageID messageID: UUID,
        modelIdOverride: String? = nil
    ) async -> Session? {
        guard let text = retrySourceText(for: messageID, in: sessionID) else { return nil }

        let sourceTitle = sessions(for: projectID).first(where: { $0.id == sessionID })?.title
        let branchTitle = sourceTitle.map { "\($0) (Branch)" }

        guard let branched = await createSession(projectID: projectID, title: branchTitle) else { return nil }

        let selectedModel = selectedModelId(for: sessionID)
        let selectedThinking = selectedThinkingLevel(for: sessionID)
        let selectedPlanMode = planModeEnabled(for: sessionID)
        let selectedPermission = permissionLevel(for: sessionID)

        if let modelIdOverride {
            let trimmed = modelIdOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                setSelectedModelId(for: branched.id, modelId: trimmed)
            } else if !selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setSelectedModelId(for: branched.id, modelId: selectedModel)
            }
        } else if !selectedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setSelectedModelId(for: branched.id, modelId: selectedModel)
        }

        setSelectedThinkingLevel(for: branched.id, level: selectedThinking)
        setPlanModeEnabled(for: branched.id, enabled: selectedPlanMode)
        setPermissionLevel(projectID: branched.projectID, sessionID: branched.id, level: selectedPermission)

        sendMessage(projectID: branched.projectID, sessionID: branched.id, text: text)
        return branched
    }

    public func pendingApproval(for sessionID: UUID) -> PendingApproval? {
        pendingApprovalsBySession[sessionID]
    }

    public func pendingPlan(for sessionID: UUID) -> ExecutionPlan? {
        pendingApprovalsBySession[sessionID]?.plan
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Untitled Project" : trimmed

        if isGatewayConfigured {
            if !isGatewayConnected {
                let connected = await ensureGatewayConnectedForChat()
                guard connected else { return nil }
            }

            guard isGatewayConnected, let gatewayClient else { return nil }
            struct Params: Codable, Sendable { var name: String }
            do {
                let res = try await gatewayClient.request(method: "projects.create", params: Params(name: finalName))
                let project: Project = try decodeGatewayPayload(res.payload, key: "project")
                upsertProject(project)
                sessionsByProject[project.id] = sessionsByProject[project.id] ?? []
                artifactsByProject[project.id] = artifactsByProject[project.id] ?? []
                runsByProject[project.id] = runsByProject[project.id] ?? []
                activeProjectID = project.id
                activeSessionID = nil
                return project
            } catch {
                gatewayConnectionState = .failed(message: error.localizedDescription)
                lastGatewayErrorMessage = error.localizedDescription
                return nil
            }
        }

        let project = Project(name: finalName)
        projects.insert(project, at: 0)
        sessionsByProject[project.id] = []
        artifactsByProject[project.id] = []
        runsByProject[project.id] = []

        activeProjectID = project.id
        activeSessionID = nil
        return project
    }

    public func renameProject(projectID: UUID, newName: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isGatewayConnected, let gatewayClient {
            struct Params: Codable, Sendable {
                var projectId: String
                var name: String
            }
            Task {
                _ = try? await gatewayClient.request(method: "projects.rename", params: Params(projectId: Self.gatewayID(projectID), name: trimmed))
            }
        }

        projects[index].name = trimmed
        projects[index].updatedAt = .now
    }

    public func deleteProject(projectID: UUID) {
        if isGatewayConnected, let gatewayClient {
            struct Params: Codable, Sendable { var projectId: String }
            Task {
                _ = try? await gatewayClient.request(method: "projects.delete", params: Params(projectId: Self.gatewayID(projectID)))
            }
            removeProjectLocally(projectID: projectID)
            return
        }

        removeProjectLocally(projectID: projectID)
    }

	    private func removeProjectLocally(projectID: UUID) {
        let removedSessionIDs = Set((sessionsByProject[projectID] ?? []).map(\.id))

        projects.removeAll { $0.id == projectID }
        sessionsByProject[projectID] = nil
        artifactsByProject[projectID] = nil
        runsByProject[projectID] = nil

	        for sessionID in removedSessionIDs {
	            messagesBySession[sessionID] = nil
            composerService.pruneAttachmentPayloads(for: sessionID, keptMessageIDs: [])
            pendingApprovalsBySession[sessionID] = nil
            livePlanBySession[sessionID] = nil
            liveAgentEventsBySession[sessionID] = nil
            activeInlineProcessBySession[sessionID] = nil
            sessionContextBySession[sessionID] = nil
            permissionLevelBySession[sessionID] = nil
            planModeEnabledBySession[sessionID] = nil
            selectedModelIdBySession[sessionID] = nil
            selectedThinkingLevelBySession[sessionID] = nil
            sessionHistoryRequestsInFlight.remove(sessionID)
            sessionHistoryLastFetchedAtBySession[sessionID] = nil
        }
        persistedProcessSummaryByMessageID = persistedProcessSummaryByMessageID.filter { summary in
            !removedSessionIDs.contains(summary.value.sessionID)
        }
        for (planID, sessionID) in planSessionByPlanID where removedSessionIDs.contains(sessionID) {
            planSessionByPlanID[planID] = nil
        }

        sessionHistoryPrefetchTasksByProject[projectID]?.cancel()
        sessionHistoryPrefetchTasksByProject[projectID] = nil

        if activeProjectID == projectID {
            activeProjectID = nil
            activeSessionID = nil
            isLeftPanelOpen = false
            isRightPanelOpen = false
            selectedArtifactPath = nil
            selectedRunID = nil
        }
    }

    public func openProject(projectID: UUID) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        activeProjectID = projectID
        activeSessionID = nil

        for (id, task) in sessionHistoryPrefetchTasksByProject where id != projectID {
            task.cancel()
            sessionHistoryPrefetchTasksByProject[id] = nil
        }

        if isGatewayConnected {
            scheduleSessionHistoryPrefetch(projectID: projectID)
            Task { [weak self] in
                guard let self else { return }
                await self.refreshProjectFromGateway(projectID: projectID)
                self.scheduleSessionHistoryPrefetch(projectID: projectID)
            }
        }
    }

    public func openSession(projectID: UUID, sessionID: UUID) {
        guard sessions(for: projectID).contains(where: { $0.id == sessionID }) else { return }
        activeProjectID = projectID
        activeSessionID = sessionID
        ensureComposerPrefs(sessionID: sessionID)

        if isGatewayConnected {
            Task { [weak self] in
                await self?.refreshSessionHistoryFromGateway(projectID: projectID, sessionID: sessionID, trigger: .interactive)
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
        if isGatewayConfigured {
            // Capture a stable local name before any gateway sync potentially replaces `projects`.
            // This is important for mapping local-only projects to a remote project by name.
            let fallbackProjectName = projects.first(where: { $0.id == projectID })?.name

            if !isGatewayConnected {
                let connected = await ensureGatewayConnectedForChat()
                guard connected else { return nil }
            }

            guard isGatewayConnected, let gatewayClient else { return nil }
            struct Params: Codable, Sendable {
                var projectId: String
                var title: String?
            }

            var effectiveProjectID = projectID
            var retriedWithResolvedProject = false

            while true {
                do {
                    let res = try await gatewayClient.request(
                        method: "sessions.create",
                        params: Params(projectId: Self.gatewayID(effectiveProjectID), title: title)
                    )
                    let session: Session = try decodeGatewayPayload(res.payload, key: "session")
                    lastGatewayErrorMessage = nil
                    upsertSession(session)
                    messagesBySession[session.id] = messagesBySession[session.id] ?? []
                    activeProjectID = session.projectID
                    activeSessionID = session.id
                    return session
                } catch {
                    if !retriedWithResolvedProject,
                       isGatewayProjectNotFoundError(error),
                       let resolvedProjectID = await resolveGatewayProjectIDForCreate(
                           requestedProjectID: projectID,
                           fallbackProjectName: fallbackProjectName
                       ) {
                        retriedWithResolvedProject = true
                        effectiveProjectID = resolvedProjectID
                        continue
                    }

                    if shouldSetGatewayFailedState(for: error) {
                        lastGatewayErrorMessage = error.localizedDescription
                        gatewayConnectionState = .failed(message: error.localizedDescription)
                    } else {
                        lastGatewayErrorMessage = error.localizedDescription
                    }
                    return nil
                }
            }
        }

        guard projects.contains(where: { $0.id == projectID }) else { return nil }

        // Local-only mode for demo/testing when gateway is not configured.
        let sessionCount = (sessionsByProject[projectID] ?? []).count + 1
        let finalTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = Session(projectID: projectID, title: finalTitle?.isEmpty == false ? finalTitle! : "Session \(sessionCount)")

        sessionsByProject[projectID, default: []].insert(session, at: 0)
        messagesBySession[session.id] = []

        activeProjectID = projectID
        activeSessionID = session.id
        ensureComposerPrefs(sessionID: session.id)
        return session
    }

    public func createSessionAndSend(projectID: UUID, firstMessage: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let session = await createSession(projectID: projectID, title: nil) else { return }
            sendMessage(projectID: session.projectID, sessionID: session.id, text: firstMessage)
        }
    }

    public func uploadProjectFiles(projectID: UUID, files: [ProjectUploadFile], createdBySessionID: UUID?) async {
        guard projects.contains(where: { $0.id == projectID }) else { return }

        let cleaned = files.compactMap { file -> ProjectUploadFile? in
            let name = sanitizeUploadFileName(file.fileName)
            guard !name.isEmpty, !file.data.isEmpty else { return nil }
            return ProjectUploadFile(fileName: name, data: file.data, mimeType: file.mimeType)
        }
        guard !cleaned.isEmpty else { return }

        if isGatewayConnected, gatewayHTTPBaseURL() != nil {
            for file in cleaned {
                let optimisticPath = "uploads/\(file.fileName)"
                _ = upsertArtifact(
                    projectID: projectID,
                    path: optimisticPath,
                    createdBySessionID: createdBySessionID,
                    origin: .userUpload,
                    sizeBytes: file.data.count,
                    indexStatus: .processing,
                    indexSummary: nil,
                    indexedAt: nil
                )

                do {
                    let response = try await uploadProjectFileToGateway(projectID: projectID, file: file)
                    if response.path != optimisticPath {
                        if var artifacts = artifactsByProject[projectID] {
                            artifacts.removeAll { $0.path == optimisticPath }
                            artifactsByProject[projectID] = artifacts
                        }
                    }
                    _ = upsertArtifact(
                        projectID: projectID,
                        path: response.path,
                        createdBySessionID: createdBySessionID,
                        origin: .userUpload,
                        sizeBytes: file.data.count,
                        indexStatus: .processing,
                        indexSummary: nil,
                        indexedAt: nil
                    )
                } catch {
                    lastGatewayErrorMessage = error.localizedDescription
                    _ = upsertArtifact(
                        projectID: projectID,
                        path: optimisticPath,
                        createdBySessionID: createdBySessionID,
                        origin: .userUpload,
                        sizeBytes: file.data.count,
                        indexStatus: .failed,
                        indexSummary: error.localizedDescription,
                        indexedAt: nil
                    )
                }
            }
        } else {
            addUploadedFiles(projectID: projectID, fileNames: cleaned.map(\.fileName), createdBySessionID: createdBySessionID)
        }

        if let projectIndex = projects.firstIndex(where: { $0.id == projectID }) {
            projects[projectIndex].updatedAt = .now
        }
    }

    public func addUploadedFiles(projectID: UUID, fileNames: [String], createdBySessionID: UUID?) {
        guard projects.contains(where: { $0.id == projectID }) else { return }

        let cleaned = fileNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleaned.isEmpty else { return }

        for name in cleaned {
            let fileName = URL(fileURLWithPath: name).lastPathComponent
            guard !fileName.isEmpty else { continue }

            let path = "uploads/\(fileName)"
            _ = upsertArtifact(
                projectID: projectID,
                path: path,
                createdBySessionID: createdBySessionID,
                origin: .userUpload,
                indexStatus: .processing
            )
        }

        if let projectIndex = projects.firstIndex(where: { $0.id == projectID }) {
            projects[projectIndex].updatedAt = .now
        }
    }

    public func removeUploadedFile(projectID: UUID, path: String) {
        guard projects.contains(where: { $0.id == projectID }) else { return }

        if var artifacts = artifactsByProject[projectID] {
            guard artifacts.first(where: { $0.path == path })?.origin == .userUpload else { return }
            artifacts.removeAll { $0.path == path }
            artifactsByProject[projectID] = artifacts
        }

        if var runs = runsByProject[projectID] {
            for idx in runs.indices {
                runs[idx].producedArtifactPaths.removeAll { $0 == path }
            }
            runsByProject[projectID] = runs
        }

        if selectedArtifactPath == path {
            selectedArtifactPath = nil
        }
        if highlightedArtifactPath == path {
            highlightedArtifactPath = nil
        }

        artifactContentCache["\(projectID.uuidString)::\(path)"] = nil
        artifactDataCache["\(projectID.uuidString)::\(path)"] = nil

        if let projectIndex = projects.firstIndex(where: { $0.id == projectID }) {
            projects[projectIndex].updatedAt = .now
        }
    }

    private func sanitizeUploadFileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "upload-\(UUID().uuidString.prefix(8)).bin"
        }
        let lastPath = URL(fileURLWithPath: trimmed).lastPathComponent
        let cleaned = lastPath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return cleaned.isEmpty ? "upload-\(UUID().uuidString.prefix(8)).bin" : cleaned
    }

    private func uploadProjectFileToGateway(projectID: UUID, file: ProjectUploadFile) async throws -> GatewayUploadResponse {
        guard let base = gatewayHTTPBaseURL() else {
            throw NSError(domain: "LabOS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gateway URL is not configured"])
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: base.appendingPathComponent("projects/\(projectID.uuidString)/uploads"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(gatewayToken)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = multipartFormDataBody(file: file, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "LabOS", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected upload response"])
        }
        guard (200...299).contains(http.statusCode) else {
            let serverMessage = String(data: data, encoding: .utf8) ?? "Upload failed"
            throw NSError(
                domain: "LabOS",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Upload failed (\(http.statusCode)): \(serverMessage)"]
            )
        }

        return try gatewayJSONDecoder.decode(GatewayUploadResponse.self, from: data)
    }

    private func multipartFormDataBody(file: ProjectUploadFile, boundary: String) -> Data {
        var body = Data()
        let lineBreak = "\r\n"
        let safeName = sanitizeUploadFileName(file.fileName)
        let mimeType = file.mimeType ?? "application/octet-stream"

        body.append(Data("--\(boundary)\(lineBreak)".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\(lineBreak)".utf8))
        body.append(Data("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)".utf8))
        body.append(file.data)
        body.append(Data(lineBreak.utf8))
        body.append(Data("--\(boundary)--\(lineBreak)".utf8))
        return body
    }

    public func renameSession(projectID: UUID, sessionID: UUID, newTitle: String) {
        guard var sessions = sessionsByProject[projectID],
              let index = sessions.firstIndex(where: { $0.id == sessionID })
        else { return }

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isGatewayConnected, let gatewayClient {
            struct Params: Codable, Sendable {
                var projectId: String
                var sessionId: String
                var title: String
            }
            Task {
                _ = try? await gatewayClient.request(
                    method: "sessions.update",
                    params: Params(projectId: Self.gatewayID(projectID), sessionId: Self.gatewayID(sessionID), title: trimmed)
                )
            }
        }

        sessions[index].title = trimmed
        sessions[index].updatedAt = .now
        sessionsByProject[projectID] = sessions
    }

    public func archiveSession(projectID: UUID, sessionID: UUID) {
        if isGatewayConnected, let gatewayClient {
            struct Params: Codable, Sendable {
                var projectId: String
                var sessionId: String
                var lifecycle: String
            }
            Task {
                _ = try? await gatewayClient.request(
                    method: "sessions.update",
                    params: Params(projectId: Self.gatewayID(projectID), sessionId: Self.gatewayID(sessionID), lifecycle: "archived")
                )
            }
        }

        setSessionLifecycle(projectID: projectID, sessionID: sessionID, lifecycle: .archived)
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
    }

    public func unarchiveSession(projectID: UUID, sessionID: UUID) {
        if isGatewayConnected, let gatewayClient {
            struct Params: Codable, Sendable {
                var projectId: String
                var sessionId: String
                var lifecycle: String
            }
            Task {
                _ = try? await gatewayClient.request(
                    method: "sessions.update",
                    params: Params(projectId: Self.gatewayID(projectID), sessionId: Self.gatewayID(sessionID), lifecycle: "active")
                )
            }
        }

        setSessionLifecycle(projectID: projectID, sessionID: sessionID, lifecycle: .active)
    }

    // Session deletion removes conversation state only. Project artifacts remain untouched.
    public func deleteSession(projectID: UUID, sessionID: UUID) {
        if isGatewayConnected, let gatewayClient {
            struct Params: Codable, Sendable {
                var projectId: String
                var sessionId: String
            }
            Task {
                _ = try? await gatewayClient.request(
                    method: "sessions.delete",
                    params: Params(projectId: Self.gatewayID(projectID), sessionId: Self.gatewayID(sessionID))
                )
            }
            removeSessionLocally(projectID: projectID, sessionID: sessionID)
            return
        }

        removeSessionLocally(projectID: projectID, sessionID: sessionID)
    }

    private func removeSessionLocally(projectID: UUID, sessionID: UUID) {
        guard var sessions = sessionsByProject[projectID] else { return }
        sessions.removeAll { $0.id == sessionID }
        sessionsByProject[projectID] = sessions

        messagesBySession[sessionID] = nil
        composerService.pruneAttachmentPayloads(for: sessionID, keptMessageIDs: [])
        pendingApprovalsBySession[sessionID] = nil
        livePlanBySession[sessionID] = nil
        liveAgentEventsBySession[sessionID] = nil
        activeInlineProcessBySession[sessionID] = nil
        persistedProcessSummaryByMessageID = persistedProcessSummaryByMessageID.filter { summary in
            summary.value.sessionID != sessionID
        }
        sessionContextBySession[sessionID] = nil
        permissionLevelBySession[sessionID] = nil
        planModeEnabledBySession[sessionID] = nil
        selectedModelIdBySession[sessionID] = nil
        selectedThinkingLevelBySession[sessionID] = nil
        pendingComposerAttachmentsBySession[sessionID] = nil
        sessionHistoryRequestsInFlight.remove(sessionID)
        sessionHistoryLastFetchedAtBySession[sessionID] = nil
        for (planID, mappedSessionID) in planSessionByPlanID where mappedSessionID == sessionID {
            planSessionByPlanID[planID] = nil
        }

        if var runs = runsByProject[projectID] {
            for index in runs.indices where runs[index].sessionID == sessionID {
                runs[index].sessionID = nil
            }
            runsByProject[projectID] = runs
        }

        if activeSessionID == sessionID {
            activeSessionID = nil
        }
    }

    private func makeSessionAttachmentReferences(
        projectID: UUID,
        sessionID: UUID,
        attachments: [ComposerAttachment]
    ) -> [ChatArtifactReference] {
        composerService.makeSessionAttachmentReferences(projectID: projectID, sessionID: sessionID, attachments: attachments)
    }

    public func sendMessage(
        projectID: UUID,
        sessionID: UUID,
        text: String,
        attachments: [ComposerAttachment]? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let effectiveAttachments = attachments ?? pendingComposerAttachments(for: sessionID)
        let attachmentRefs = makeSessionAttachmentReferences(
            projectID: projectID,
            sessionID: sessionID,
            attachments: effectiveAttachments
        )

        beginInlineProcess(sessionID: sessionID, runID: UUID())
        clearLiveAgentEvents(sessionID: sessionID)

        if isGatewayConfigured {
            // Gateway-configured mode (real backend): never silently fall back to mock.
            let localUserMessage = ChatMessage(sessionID: sessionID, role: .user, text: trimmed, artifactRefs: attachmentRefs)
            messagesBySession[sessionID, default: []].append(localUserMessage)
            pendingLocalUserEchosBySession[sessionID, default: []].append(
                PendingLocalUserEcho(
                    localId: localUserMessage.id,
                    text: trimmed,
                    createdAt: localUserMessage.createdAt,
                    artifactRefs: attachmentRefs,
                    attachments: effectiveAttachments
                )
            )
            setAttachmentPayload(
                for: sessionID,
                messageID: localUserMessage.id,
                attachments: effectiveAttachments
            )
            sendGatewayChatMessage(
                projectID: projectID,
                sessionID: sessionID,
                text: trimmed,
                attachmentRefs: attachmentRefs,
                attachments: effectiveAttachments
            )
            clearPendingComposerAttachments(sessionID: sessionID)
            return
        }

        let userMessage = ChatMessage(sessionID: sessionID, role: .user, text: trimmed, artifactRefs: attachmentRefs)
        messagesBySession[sessionID, default: []].append(userMessage)
        setAttachmentPayload(
            for: sessionID,
            messageID: userMessage.id,
            attachments: effectiveAttachments
        )
        clearPendingComposerAttachments(sessionID: sessionID)

        let existingArtifacts = artifactsByProject[projectID] ?? []

        Task { [weak self] in
            guard let self else { return }
            let response = await backend.generateAssistantResponse(
                projectID: projectID,
                sessionID: sessionID,
                userText: trimmed,
                existingArtifacts: existingArtifacts
            )
            self.applyAssistantResponse(projectID: projectID, sessionID: sessionID, response: response)
        }
    }

    private func sendGatewayChatMessage(
        projectID: UUID,
        sessionID: UUID,
        text: String,
        attachmentRefs: [ChatArtifactReference] = [],
        attachments: [ComposerAttachment] = [],
        overwriteMessageID: UUID? = nil
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let connected = await self.ensureGatewayConnectedForChat()
            guard connected, self.isGatewayConnected, let gatewayClient = self.gatewayClient else {
                self.appendGatewayConnectionError(sessionID: sessionID)
                return
            }

            let params = self.makeGatewayChatParams(
                projectID: projectID,
                sessionID: sessionID,
                text: text,
                attachmentRefs: attachmentRefs,
                attachments: attachments,
                overwriteMessageID: overwriteMessageID
            )
            do {
                _ = try await gatewayClient.request(
                    method: "chat.send",
                    params: params
                )
                self.lastGatewayErrorMessage = nil
            } catch {
                self.lastGatewayErrorMessage = error.localizedDescription
                let recovered = await self.recoverMissingGatewaySessionAndResend(
                    error: error,
                    projectID: projectID,
                    sessionID: sessionID,
                    text: text,
                    attachmentRefs: attachmentRefs,
                    attachments: attachments,
                    overwriteMessageID: overwriteMessageID,
                    gatewayClient: gatewayClient
                )
                guard !recovered else { return }
                self.finalizeInlineProcess(sessionID: sessionID, failed: true)
                self.clearLiveAgentEvents(sessionID: sessionID)
                let sys = ChatMessage(
                    sessionID: sessionID,
                    role: .system,
                    text: "Send failed: \(error.localizedDescription)"
                )
                self.messagesBySession[sessionID, default: []].append(sys)
            }
        }
    }

    private func makeGatewayChatParams(
        projectID: UUID,
        sessionID: UUID,
        text: String,
        attachmentRefs: [ChatArtifactReference] = [],
        attachments: [ComposerAttachment] = [],
        overwriteMessageID: UUID? = nil
    ) -> GatewayChatSendParams {
        let modelIdRaw = selectedModelId(for: sessionID).trimmingCharacters(in: .whitespacesAndNewlines)
        let modelId = modelIdRaw.isEmpty ? nil : modelIdRaw
        let thinking = selectedThinkingLevel(for: sessionID)
        let planMode = planModeEnabled(for: sessionID)
        let permissionLevel = permissionLevel(for: sessionID)
        let payloadAttachments: [GatewayChatAttachment]? = attachmentRefs.isEmpty ? nil : attachmentRefs.enumerated().map { index, ref in
            let source: ComposerAttachment? = {
                if let artifactID = ref.artifactID {
                    if let direct = attachments.first(where: { $0.id == artifactID }) {
                        return direct
                    }
                }
                if attachments.indices.contains(index) {
                    return attachments[index]
                }
                return attachments.first(where: { $0.displayName == ref.displayText })
            }()
            return GatewayChatAttachment(
                id: ref.artifactID?.uuidString ?? source?.id.uuidString ?? UUID().uuidString,
                scope: ref.scope ?? "session",
                name: ref.displayText,
                path: ref.path,
                mimeType: source?.mimeType ?? ref.mimeType,
                inlineDataBase64: source?.inlineDataBase64 ?? ref.inlineDataBase64,
                byteCount: source?.byteCount ?? ref.byteCount
            )
        }
        return GatewayChatSendParams(
            projectId: Self.gatewayID(projectID),
            sessionId: Self.gatewayID(sessionID),
            text: text,
            overwriteMessageId: overwriteMessageID.map(Self.gatewayID),
            attachments: payloadAttachments,
            modelId: modelId,
            thinkingLevel: thinking,
            planMode: planMode,
            permissionLevel: permissionLevel
        )
    }

    private func appendGatewayConnectionError(sessionID: UUID) {
        activeInlineProcessBySession[sessionID] = nil
        clearLiveAgentEvents(sessionID: sessionID)
        let detail: String
        switch gatewayConnectionState {
        case .disconnected:
            detail = "Disconnected"
        case .connecting:
            detail = "Connecting…"
        case let .failed(message):
            detail = "Failed: \(message)"
        case .connected:
            detail = "Connected"
        }
        let sys = ChatMessage(
            sessionID: sessionID,
            role: .system,
            text: "Gateway not connected (\(detail)). Open Settings and connect to your Hub (e.g. ws://127.0.0.1:8787/ws)."
        )
        messagesBySession[sessionID, default: []].append(sys)
    }

    private func recoverMissingGatewaySessionAndResend(
        error: Error,
        projectID: UUID,
        sessionID: UUID,
        text: String,
        attachmentRefs: [ChatArtifactReference],
        attachments: [ComposerAttachment],
        overwriteMessageID: UUID?,
        gatewayClient: GatewayClient
    ) async -> Bool {
        guard isGatewaySessionNotFoundError(error) else { return false }
        _ = overwriteMessageID
        let nonSystemMessageCount = localNonSystemMessageCount(for: sessionID)
        guard Self.shouldAutoRecoverMissingGatewaySession(localNonSystemMessageCount: nonSystemMessageCount) else {
            return false
        }

        let previousActiveProjectID = activeProjectID
        let previousActiveSessionID = activeSessionID

        let title = sessions(for: projectID).first(where: { $0.id == sessionID })?.title
        let modelId = selectedModelId(for: sessionID)
        let thinking = selectedThinkingLevel(for: sessionID)
        let planMode = planModeEnabled(for: sessionID)
        let permission = permissionLevel(for: sessionID)

        guard let recovered = await createSession(projectID: projectID, title: title) else {
            return false
        }

        if !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setSelectedModelId(for: recovered.id, modelId: modelId)
        }
        setSelectedThinkingLevel(for: recovered.id, level: thinking)
        setPlanModeEnabled(for: recovered.id, enabled: planMode)
        setPermissionLevel(projectID: recovered.projectID, sessionID: recovered.id, level: permission)

        let params = makeGatewayChatParams(
            projectID: recovered.projectID,
            sessionID: recovered.id,
            text: text,
            attachmentRefs: attachmentRefs,
            attachments: attachments,
            overwriteMessageID: nil
        )
        do {
            _ = try await gatewayClient.request(method: "chat.send", params: params)
            messagesBySession[recovered.id, default: []].append(
                ChatMessage(
                    sessionID: recovered.id,
                    role: .system,
                    text: "Recovered broken session state and resent your message."
                )
            )
            return true
        } catch {
            if activeSessionID == recovered.id {
                activeProjectID = previousActiveProjectID
                activeSessionID = previousActiveSessionID
            }
            return false
        }
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

    private func localNonSystemMessageCount(for sessionID: UUID) -> Int {
        (messagesBySession[sessionID] ?? []).reduce(into: 0) { count, message in
            if message.role != .system {
                count += 1
            }
        }
    }

    private func isGatewayProjectNotFoundError(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("project") && (lower.contains("not found") || lower.contains("cannot find"))
    }

    private func isGatewaySessionNotFoundError(_ error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        return lower.contains("session") && lower.contains("not found")
    }

    private func shouldSetGatewayFailedState(for error: Error) -> Bool {
        let lower = error.localizedDescription.lowercased()
        if lower.contains("not found") || lower.contains("cannot find") {
            return false
        }
        if lower.contains("bad request") || lower.contains("missing ") || lower.contains("invalid ") {
            return false
        }
        return true
    }

    private func resolveGatewayProjectIDForCreate(
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

    private func createGatewayProjectForMissingLocalProject(name: String) async -> UUID? {
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
        guard let pending = pendingApprovalsBySession.removeValue(forKey: sessionID) else { return }

        if isGatewayConnected, let gatewayClient {
            struct Params: Codable, Sendable {
                var planId: UUID
                var decision: String
            }
            Task {
                _ = try? await gatewayClient.request(method: "exec.approval.resolve", params: Params(planId: pending.planId, decision: "reject"))
            }
            return
        }

        let cancellation = ChatMessage(
            sessionID: sessionID,
            role: .system,
            text: "Plan canceled. No run was created for project \(pending.projectId.uuidString.prefix(8))."
        )
        messagesBySession[sessionID, default: []].append(cancellation)
    }

    public func approvePlan(sessionID: UUID, judgmentResponses: JudgmentResponses? = nil) {
        guard let pending = pendingApprovalsBySession.removeValue(forKey: sessionID) else { return }

        if isGatewayConnected, let gatewayClient {
            struct Params: Codable, Sendable {
                var planId: UUID
                var decision: String
                var judgmentResponses: JudgmentResponses?
            }
            Task {
                _ = try? await gatewayClient.request(
                    method: "exec.approval.resolve",
                    params: Params(planId: pending.planId, decision: "approve", judgmentResponses: judgmentResponses)
                )
            }
            return
        }

        let plan = pending.plan
        let stepDetails = plan.steps.map { step in
            formatStepDetail(step: step)
        }

        let run = RunRecord(
            projectID: plan.projectID,
            sessionID: sessionID,
            status: .queued,
            currentStep: 0,
            totalSteps: max(plan.steps.count, 1),
            logSnippet: "Queued and waiting for execution.",
            stepTitles: plan.steps.map(\.title),
            stepDetails: stepDetails,
            activity: [
                RunActionEvent(
                    type: .info,
                    summary: "Plan approved",
                    detail: "Execution queued with \(max(plan.steps.count, 1)) steps."
                )
            ]
        )

        runsByProject[plan.projectID, default: []].insert(run, at: 0)
        selectedRunID = run.id

        appendRunActivity(
            projectID: plan.projectID,
            runID: run.id,
            sessionID: sessionID,
            type: .info,
            summary: "Execution started (\(max(plan.steps.count, 1)) planned steps)",
            detail: "Run is queued and will stream tool calls and command outputs."
        )

        Task { [weak self] in
            guard let self else { return }
            await self.execute(plan: plan, runID: run.id)
        }
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
        switch run.status {
        case .queued:
            return "Queued"
        case .running:
            return "Running step \(run.currentStep)/\(max(run.totalSteps, 1))"
        case .succeeded:
            return "Succeeded"
        case .failed:
            return "Failed"
        case .canceled:
            return "Canceled"
        }
    }

    public func fetchArtifactContent(projectID: UUID, path: String) async -> String {
        let key = "\(projectID.uuidString)::\(path)"
        if let cached = artifactContentCache[key] {
            return cached
        }

        if isGatewayConnected, let base = gatewayHTTPBaseURL() {
            var components = URLComponents(url: base.appendingPathComponent("projects/\(projectID.uuidString)/artifacts/content"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "path", value: path)]
            if let url = components?.url {
                var req = URLRequest(url: url)
                req.setValue("Bearer \(gatewayToken)", forHTTPHeaderField: "Authorization")
                if let (data, _) = try? await URLSession.shared.data(for: req) {
                    let content = String(decoding: data, as: UTF8.self)
                    artifactContentCache[key] = content
                    return content
                }
            }
        }

        let content = await backend.fetchArtifactContent(projectID: projectID, path: path)
        artifactContentCache[key] = content
        return content
    }

    public func fetchArtifactData(projectID: UUID, path: String) async -> Data? {
        let key = "\(projectID.uuidString)::\(path)"
        if let cached = artifactDataCache[key] {
            return cached
        }

        guard isGatewayConnected, let base = gatewayHTTPBaseURL() else { return nil }

        var components = URLComponents(url: base.appendingPathComponent("projects/\(projectID.uuidString)/artifacts/raw"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components?.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(gatewayToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            artifactDataCache[key] = data
            return data
        } catch {
            return nil
        }
    }

    private func applyAssistantResponse(projectID: UUID, sessionID: UUID, response: AssistantResponse) {
        clearLiveAgentEvents(sessionID: sessionID)
        let assistant = ChatMessage(
            sessionID: sessionID,
            role: .assistant,
            text: response.text,
            artifactRefs: response.artifactRefs,
            proposedPlan: response.proposedPlan
        )

        messagesBySession[sessionID, default: []].append(assistant)
        finalizeInlineProcess(sessionID: sessionID, failed: false, assistantMessageIDFallback: assistant.id)
        if let plan = response.proposedPlan {
            let pending = PendingApproval(
                planId: plan.id,
                projectId: projectID,
                sessionId: sessionID,
                agentRunId: UUID(),
                plan: plan,
                required: true,
                judgment: nil
            )
            pendingApprovalsBySession[sessionID] = pending
        }
    }

    private func execute(plan: ExecutionPlan, runID: UUID) async {
        let totalSteps = max(plan.steps.count, 1)

        for (idx, step) in plan.steps.enumerated() {
            let detail = formatStepDetail(step: step)

            mutateRun(projectID: plan.projectID, runID: runID) { run in
                run.status = .running
                run.currentStep = idx + 1
                run.logSnippet = detail
            }

            appendRunActivity(
                projectID: plan.projectID,
                runID: runID,
                sessionID: plan.sessionID,
                type: .toolCall,
                summary: "Tool call · Step \(idx + 1)/\(totalSteps): \(step.runtime.rawValue)",
                detail: toolResultTrace(for: step)
            )
            try? await Task.sleep(for: .milliseconds(120))

            for command in commandTrace(for: step) {
                appendRunActivity(
                    projectID: plan.projectID,
                    runID: runID,
                    sessionID: plan.sessionID,
                    type: .command,
                    summary: "Command executed: \(command)",
                    detail: commandOutput(for: step, command: command)
                )
                try? await Task.sleep(for: .milliseconds(120))
            }

            if step.outputs.isEmpty {
                appendRunActivity(
                    projectID: plan.projectID,
                    runID: runID,
                    sessionID: plan.sessionID,
                    type: .info,
                    summary: "No artifact output declared",
                    detail: "Step \(idx + 1) completed with no file output."
                )
            } else {
                for output in step.outputs {
                    appendRunActivity(
                        projectID: plan.projectID,
                        runID: runID,
                        sessionID: plan.sessionID,
                        type: .output,
                        summary: "Output updated: \(output)",
                        detail: "Artifact written successfully."
                    )
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }

            try? await Task.sleep(for: .milliseconds(550))
        }

        let outputPaths = unique(plan.steps.flatMap(\.outputs))
        let artifacts = outputPaths.map { path in
            upsertArtifact(
                projectID: plan.projectID,
                path: path,
                createdBySessionID: plan.sessionID,
                origin: .generated
            )
        }

        mutateRun(projectID: plan.projectID, runID: runID) { run in
            run.status = .succeeded
            run.currentStep = run.totalSteps
            run.completedAt = .now
            run.logSnippet = "Completed all planned steps."
            run.producedArtifactPaths = outputPaths
        }

        appendRunActivity(
            projectID: plan.projectID,
            runID: runID,
            sessionID: plan.sessionID,
            type: .info,
            summary: "Run completed",
            detail: "Execution finished successfully."
        )

        let refs = artifacts.map { artifact in
            ChatArtifactReference(
                displayText: artifact.path,
                projectID: artifact.projectID,
                path: artifact.path,
                artifactID: artifact.id
            )
        }

        let doneMessage = ChatMessage(
            sessionID: plan.sessionID,
            role: .assistant,
            text: finalReportText(
                runID: runID,
                stepCount: max(plan.steps.count, 1),
                outputPaths: outputPaths
            ),
            artifactRefs: refs
        )
        messagesBySession[plan.sessionID, default: []].append(doneMessage)

        if let first = refs.first {
            openArtifactReference(first)
        }
    }

    @discardableResult
    private func upsertArtifact(
        projectID: UUID,
        path: String,
        createdBySessionID: UUID?,
        origin: ArtifactOrigin,
        sizeBytes: Int? = nil,
        indexStatus: ArtifactIndexStatus? = nil,
        indexSummary: String? = nil,
        indexedAt: Date? = nil
    ) -> Artifact {
        var artifacts = artifactsByProject[projectID, default: []]

        if let idx = artifacts.firstIndex(where: { $0.path == path }) {
            artifacts[idx].modifiedAt = .now
            artifacts[idx].createdBySessionID = createdBySessionID
            artifacts[idx].origin = origin
            if let sizeBytes {
                artifacts[idx].sizeBytes = max(sizeBytes, 0)
            }
            if let indexStatus {
                artifacts[idx].indexStatus = indexStatus
                if indexStatus == .processing {
                    artifacts[idx].indexSummary = nil
                    artifacts[idx].indexedAt = nil
                }
            }
            if let indexSummary {
                artifacts[idx].indexSummary = indexSummary
            }
            if let indexedAt {
                artifacts[idx].indexedAt = indexedAt
            }
            let updated = artifacts[idx]
            artifactsByProject[projectID] = artifacts
            return updated
        }

        let artifact = Artifact(
            projectID: projectID,
            path: path,
            origin: origin,
            sizeBytes: sizeBytes ?? Int.random(in: 4_096...980_000),
            createdBySessionID: createdBySessionID,
            indexStatus: indexStatus,
            indexSummary: indexSummary,
            indexedAt: indexedAt
        )
        artifacts.append(artifact)
        artifactsByProject[projectID] = artifacts
        return artifact
    }

    private func mutateRun(projectID: UUID, runID: UUID, mutate: (inout RunRecord) -> Void) {
        guard var runs = runsByProject[projectID],
              let idx = runs.firstIndex(where: { $0.id == runID })
        else {
            return
        }

        let previous = runs[idx]
        mutate(&runs[idx])
        let updated = runs[idx]
        runsByProject[projectID] = runs
        emitRunCompletionSignalIfNeeded(projectID: projectID, previousRun: previous, updatedRun: updated)
    }

    private static func isTerminalRunStatus(_ status: RunStatus) -> Bool {
        switch status {
        case .succeeded, .failed, .canceled:
            return true
        case .queued, .running:
            return false
        }
    }

    private func emitRunCompletionSignalIfNeeded(projectID: UUID, previousRun: RunRecord, updatedRun: RunRecord) {
        guard !Self.isTerminalRunStatus(previousRun.status),
              Self.isTerminalRunStatus(updatedRun.status)
        else {
            return
        }

        guard runCompletionNotificationsEnabled else {
            return
        }

        guard observedTerminalRunIDs.insert(updatedRun.id).inserted else {
            return
        }

        let projectName = projects.first(where: { $0.id == projectID })?.name ?? "LabOS Project"
        latestRunCompletionSignal = RunCompletionSignal(
            projectID: projectID,
            runID: updatedRun.id,
            sessionID: updatedRun.sessionID,
            projectName: projectName,
            status: updatedRun.status,
            completedAt: updatedRun.completedAt ?? .now
        )
    }

    private func ensureComposerPrefs(sessionID: UUID) {
        composerService.ensureComposerPrefs(sessionID: sessionID)
    }

    private func normalizeThinkingPrefs(sessionID: UUID) {
        composerService.ensureComposerPrefs(sessionID: sessionID)
    }

    private func setSessionLifecycle(projectID: UUID, sessionID: UUID, lifecycle: SessionLifecycle) {
        guard var sessions = sessionsByProject[projectID],
              let idx = sessions.firstIndex(where: { $0.id == sessionID })
        else { return }

        sessions[idx].lifecycle = lifecycle
        sessions[idx].updatedAt = .now
        sessionsByProject[projectID] = sessions
    }

    private func setTemporaryArtifactHighlight(_ path: String) {
        highlightedArtifactPath = path
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.highlightedArtifactPath == path else { return }
            await MainActor.run {
                self.highlightedArtifactPath = nil
            }
        }
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

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    private func formatStepDetail(step: PlanStep) -> String {
        let runtime = step.runtime.rawValue
        let inputSummary = step.inputs.isEmpty ? "none" : step.inputs.joined(separator: ", ")
        let outputSummary = step.outputs.isEmpty ? "none" : step.outputs.joined(separator: ", ")
        return "\(runtime) runtime. Inputs: \(inputSummary). Outputs: \(outputSummary)."
    }

    private func commandTrace(for step: PlanStep) -> [String] {
        let input = step.inputs.first ?? "input.dat"
        let output = step.outputs.first ?? "artifacts/output.dat"

        switch step.runtime {
        case .download:
            return ["curl -L \"\(input)\" -o \(output)"]
        case .python:
            return ["python scripts/run_step.py --input \(input) --output \(output)"]
        case .shell:
            return ["sh -lc \"\(step.title.lowercased())\""]
        case .hpcJob:
            return ["sbatch jobs/step_job.sh --input \(input) --output \(output)"]
        case .notebook:
            return ["jupyter nbconvert --execute \(input) --to notebook --output \(output)"]
        }
    }

    private func commandOutput(for step: PlanStep, command: String) -> String {
        switch step.runtime {
        case .download:
            return "HTTP 200 OK. Downloaded source data and saved requested output."
        case .python:
            return "Python finished successfully. Features computed and written to target artifact."
        case .shell:
            return "Shell command exited with code 0."
        case .hpcJob:
            return "Job submitted and completed. Exit status 0."
        case .notebook:
            return "Notebook executed without errors and produced rendered output."
        }
    }

    private func toolResultTrace(for step: PlanStep) -> String {
        switch step.runtime {
        case .download:
            return "Downloader initialized request, validated network path, and staged incoming file."
        case .python:
            return "Python tool loaded inputs and executed the requested transformation pipeline."
        case .shell:
            return "Shell tool prepared environment and executed scripted operation."
        case .hpcJob:
            return "HPC client prepared submission payload and tracked completion."
        case .notebook:
            return "Notebook runner executed cells and collected artifacts."
        }
    }

    private func appendRunActivity(
        projectID: UUID,
        runID: UUID,
        sessionID: UUID,
        type: RunActionType,
        summary: String,
        detail: String
    ) {
        let event = RunActionEvent(type: type, summary: summary, detail: detail)
        mutateRun(projectID: projectID, runID: runID) { run in
            run.activity.append(event)
        }
        let body = detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? summary
            : "\(summary)\n\(detail)"

        let message = ChatMessage(
            sessionID: sessionID,
            role: .tool,
            text: body
        )
        messagesBySession[sessionID, default: []].append(message)
    }

    private func finalReportText(runID: UUID, stepCount: Int, outputPaths: [String]) -> String {
        let duration = run(runID: runID).map { record in
            (record.completedAt ?? .now).timeIntervalSince(record.initiatedAt)
        } ?? 0

        let durationText = durationFormatter.string(from: duration) ?? "under 1m"
        let outputs = outputPaths.isEmpty
            ? "- No files were generated."
            : outputPaths.map { "- `\($0)`" }.joined(separator: "\n")

        return """
        ## Final report
        - Status: Succeeded
        - Completed steps: \(stepCount)/\(stepCount)
        - Runtime: \(durationText)

        ### Generated outputs
        \(outputs)
        """
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
