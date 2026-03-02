import CryptoKit
import Foundation

public enum GatewayConnectionState: Hashable, Sendable {
    case disconnected
    case connecting
    case connected(connectionID: UUID)
    case failed(message: String)
}

public enum GatewayEvent: Sendable {
    case projectsUpdated(Project, change: String)
    case sessionsUpdated(Session, change: String)
    case sessionPermissionUpdated(SessionPermissionUpdatedPayload)
    case chatMessageCreated(projectID: UUID, sessionID: UUID, message: ChatMessage)
    case sessionContextUpdated(SessionContextUpdatedPayload)
    case runsUpdated(projectID: UUID, run: RunRecord, change: String)
    case runsLogDelta(RunLogDeltaPayload)
    case artifactsUpdated(projectID: UUID, artifact: Artifact, change: String)
    case settingsOpenAIUpdated(OpenAIHubSettingsStatus)
}

public struct SessionPermissionUpdatedPayload: Hashable, Codable, Sendable {
    public var projectId: UUID
    public var sessionId: UUID
    public var level: String
    public var updatedAt: Date
}

public struct SessionContextUpdatedPayload: Hashable, Codable, Sendable {
    public var projectId: UUID
    public var sessionId: UUID
    public var modelId: String?
    public var contextWindowTokens: Int
    public var usedInputTokens: Int
    public var usedTokens: Int
    public var remainingTokens: Int
    public var updatedAt: Date
}

public struct AgentPlanUpdatedPayload: Hashable, Codable, Sendable {
    public struct PlanItem: Hashable, Codable, Sendable {
        public var step: String
        public var status: String
    }

    public var agentRunId: UUID
    public var projectId: UUID
    public var sessionId: UUID
    public var explanation: String?
    public var plan: [PlanItem]
}

public struct RunLogDeltaPayload: Hashable, Codable, Sendable {
    public var projectId: UUID
    public var runId: UUID
    public var stream: String
    public var delta: String
}

@MainActor
public final class GatewayClient: ObservableObject {
    @Published public private(set) var connectionState: GatewayConnectionState = .disconnected

    private static let maxOutgoingFrameBytes = 4 * 1024 * 1024

    private let wsURL: URL
    private let token: String
    private let deviceID: UUID
    private let deviceName: String

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var urlSession: URLSession?
    private var pending: [String: CheckedContinuation<GatewayResponseFrame, Error>] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var eventsContinuation: AsyncStream<GatewayEvent>.Continuation?
    public private(set) var events: AsyncStream<GatewayEvent>

    public init(wsURL: URL, token: String, deviceID: UUID = UUID(), deviceName: String = "Epoch iPhone") {
        self.wsURL = wsURL
        self.token = token
        self.deviceID = deviceID
        self.deviceName = deviceName

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        self.decoder = decoder

        var continuation: AsyncStream<GatewayEvent>.Continuation?
        self.events = AsyncStream<GatewayEvent> { cont in
            continuation = cont
        }
        self.eventsContinuation = continuation
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    public func connect(scopes: [String] = ["operator.read", "operator.write", "operator.approvals"]) async {
        switch connectionState {
        case .connecting, .connected:
            return
        case .disconnected, .failed:
            break
        }

        if case .failed = connectionState {
            receiveTask?.cancel()
            receiveTask = nil
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            urlSession?.invalidateAndCancel()
            urlSession = nil
        }

        // URLSessionWebSocketTask throws an Objective-C exception (crash) if the URL scheme
        // is not ws/wss. Validate before calling into CFNetwork.
        let scheme = wsURL.scheme?.lowercased() ?? ""
        guard scheme == "ws" || scheme == "wss" else {
            connectionState = .failed(message: "Gateway WS URL must start with ws:// or wss://")
            return
        }

        connectionState = .connecting

        let session = URLSession(configuration: .default)
        self.urlSession = session
        let task = session.webSocketTask(with: wsURL)
        self.webSocketTask = task
        task.resume()

        do {
            // 1) Wait for connect.challenge
            let challengeFrame = try await receiveOneFrame(from: task)
            guard case let .event(eventFrame) = challengeFrame,
                  eventFrame.event == "connect.challenge"
            else {
                throw GatewayClientError.unexpectedHandshake
            }

            let challenge: ConnectChallengePayload = try decodeEventPayload(eventFrame.payload)

            // 2) Send connect request
            let signature = hmacSignatureBase64URL(token: token, nonce: challenge.nonce)
            let connectID = UUID().uuidString

            let params = ConnectRequestParams(
                minProtocol: 1,
                maxProtocol: 1,
                role: "operator",
                auth: .init(token: token, signature: signature),
                device: .init(id: deviceID, name: deviceName, platform: "iOS", osVersion: ProcessInfo.processInfo.operatingSystemVersionString),
                client: .init(name: "EpochApp", version: "0.1.0"),
                scopes: scopes
            )

            try await sendRequestFrame(task, id: connectID, method: "connect", params: params)

            // 3) Wait for connect response
            let responseFrame = try await receiveOneFrame(from: task)
            guard case let .response(res) = responseFrame, res.id == connectID else {
                throw GatewayClientError.unexpectedHandshake
            }
            guard res.ok else {
                throw GatewayClientError.serverRejected(res.error?.message ?? "connect failed")
            }

            let connectionIdValue: UUID = try decodePayloadValue(res.payload, key: "connectionId")
            connectionState = .connected(connectionID: connectionIdValue)

            // Start receive loop for everything else.
            startReceiveLoop(task)
        } catch {
            connectionState = .failed(message: String(describing: error))
            failPendingRequests(error)
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
            urlSession?.invalidateAndCancel()
            urlSession = nil
        }
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        failPendingRequests(GatewayClientError.connectionClosed("Disconnected"))
        connectionState = .disconnected
    }

    public func request<Params: Encodable>(
        method: String,
        params: Params
    ) async throws -> GatewayResponseFrame {
        guard let task = webSocketTask else {
            throw GatewayClientError.notConnected
        }
        let id = UUID().uuidString

        let response = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<GatewayResponseFrame, Error>) in
            pending[id] = cont
            Task {
                do {
                    try await sendRequestFrame(task, id: id, method: method, params: params)
                } catch {
                    pending[id] = nil
                    cont.resume(throwing: error)
                }
            }
        }
        return response
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let frame = try await self.receiveOneFrame(from: task)
                    await MainActor.run {
                        self.handle(frame: frame)
                    }
                } catch {
                    await MainActor.run {
                        self.connectionState = .failed(message: String(describing: error))
                        self.failPendingRequests(GatewayClientError.connectionClosed(String(describing: error)))
                        self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                        self.webSocketTask = nil
                        self.urlSession?.invalidateAndCancel()
                        self.urlSession = nil
                    }
                    return
                }
            }
        }
    }

    private func handle(frame: GatewayIncomingFrame) {
        switch frame {
        case let .response(res):
            guard let cont = pending.removeValue(forKey: res.id) else { return }
            if res.ok {
                cont.resume(returning: res)
            } else {
                cont.resume(throwing: GatewayClientError.serverRejected(res.error?.message ?? "request failed"))
            }
        case let .event(eventFrame):
            handle(eventFrame: eventFrame)
        }
    }

    private func handle(eventFrame: GatewayEventFrame) {
        switch eventFrame.event {
        case "projects.updated":
            if let project: Project = try? decodeEventPayload(eventFrame.payload, key: "project"),
               let change: String = try? decodeEventPayload(eventFrame.payload, key: "change") {
                eventsContinuation?.yield(.projectsUpdated(project, change: change))
            }
        case "sessions.updated":
            if let session: Session = try? decodeEventPayload(eventFrame.payload, key: "session"),
               let change: String = try? decodeEventPayload(eventFrame.payload, key: "change") {
                eventsContinuation?.yield(.sessionsUpdated(session, change: change))
            }
        case "sessions.permission.updated":
            if let payload: SessionPermissionUpdatedPayload = try? decodeEventPayload(eventFrame.payload) {
                eventsContinuation?.yield(.sessionPermissionUpdated(payload))
            }
        case "chat.message.created":
            if let projectID: UUID = try? decodeEventPayload(eventFrame.payload, key: "projectId"),
               let sessionID: UUID = try? decodeEventPayload(eventFrame.payload, key: "sessionId"),
               let message: ChatMessage = try? decodeEventPayload(eventFrame.payload, key: "message") {
                eventsContinuation?.yield(.chatMessageCreated(projectID: projectID, sessionID: sessionID, message: message))
            }
        case "sessions.context.updated":
            if let payload: SessionContextUpdatedPayload = try? decodeEventPayload(eventFrame.payload) {
                eventsContinuation?.yield(.sessionContextUpdated(payload))
            }
        case "runs.updated":
            if let projectID: UUID = try? decodeEventPayload(eventFrame.payload, key: "projectId"),
               let run: RunRecord = try? decodeEventPayload(eventFrame.payload, key: "run"),
               let change: String = try? decodeEventPayload(eventFrame.payload, key: "change") {
                eventsContinuation?.yield(.runsUpdated(projectID: projectID, run: run, change: change))
            }
        case "runs.log.delta":
            if let payload: RunLogDeltaPayload = try? decodeEventPayload(eventFrame.payload) {
                eventsContinuation?.yield(.runsLogDelta(payload))
            }
        case "artifacts.updated":
            if let projectID: UUID = try? decodeEventPayload(eventFrame.payload, key: "projectId"),
               let artifact: Artifact = try? decodeEventPayload(eventFrame.payload, key: "artifact"),
               let change: String = try? decodeEventPayload(eventFrame.payload, key: "change") {
                eventsContinuation?.yield(.artifactsUpdated(projectID: projectID, artifact: artifact, change: change))
            }
        case "settings.openai.updated":
            if let payload: OpenAIHubSettingsStatus = try? decodeEventPayload(eventFrame.payload) {
                eventsContinuation?.yield(.settingsOpenAIUpdated(payload))
            }
        default:
            return
        }
    }

    private func receiveOneFrame(from task: URLSessionWebSocketTask) async throws -> GatewayIncomingFrame {
        let message = try await task.receive()
        let data: Data
        switch message {
        case let .data(raw):
            data = raw
        case let .string(text):
            data = Data(text.utf8)
        @unknown default:
            throw GatewayClientError.unexpectedFrame
        }

        return try decoder.decode(GatewayIncomingFrame.self, from: data)
    }

    private func sendRequestFrame<Params: Encodable>(
        _ task: URLSessionWebSocketTask,
        id: String,
        method: String,
        params: Params
    ) async throws {
        let frame = GatewayOutgoingRequest(id: id, method: method, params: params)
        let data = try encoder.encode(frame)
        try Self.validateOutgoingFrameSize(bytes: data.count)
        try await task.send(.data(data))
    }

    private func failPendingRequests(_ error: Error) {
        let active = pending
        pending.removeAll()
        for (_, continuation) in active {
            continuation.resume(throwing: error)
        }
    }

    static func validateOutgoingFrameSize(bytes: Int) throws {
        guard bytes <= maxOutgoingFrameBytes else {
            throw GatewayClientError.requestTooLarge(bytes: bytes, maxBytes: maxOutgoingFrameBytes)
        }
    }

    var pendingRequestCountForTesting: Int {
        pending.count
    }

    func registerPendingRequestForTesting(id: String) async throws -> GatewayResponseFrame {
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
        }
    }

    func failPendingRequestsForTesting(_ error: Error) {
        failPendingRequests(error)
    }

    static var maxOutgoingFrameBytesForTesting: Int {
        maxOutgoingFrameBytes
    }

    static func validateOutgoingFrameSizeForTesting(bytes: Int) throws {
        try validateOutgoingFrameSize(bytes: bytes)
    }

    private func decodeEventPayload<T: Decodable>(_ payload: [String: JSONValue], key: String) throws -> T {
        guard let value = payload[key] else {
            throw GatewayClientError.missingPayloadKey(key)
        }
        let data = try encoder.encode(value)
        return try decoder.decode(T.self, from: data)
    }

    private func decodeEventPayload<T: Decodable>(_ payload: [String: JSONValue]) throws -> T {
        let data = try encoder.encode(JSONValue.object(payload))
        return try decoder.decode(T.self, from: data)
    }

    private func decodePayloadValue<T: Decodable>(_ payload: [String: JSONValue]?, key: String) throws -> T {
        guard let payload, let value = payload[key] else {
            throw GatewayClientError.missingPayloadKey(key)
        }
        let data = try encoder.encode(value)
        return try decoder.decode(T.self, from: data)
    }

    private func hmacSignatureBase64URL(token: String, nonce: String) -> String {
        let key = SymmetricKey(data: Data(token.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: key)
        return Data(mac).base64URLEncodedString()
    }
}

private struct GatewayOutgoingRequest<Params: Encodable>: Encodable {
    let type = "req"
    let id: String
    let method: String
    let params: Params
}

private enum GatewayClientError: Error, LocalizedError {
    case notConnected
    case unexpectedHandshake
    case unexpectedFrame
    case serverRejected(String)
    case missingPayloadKey(String)
    case connectionClosed(String)
    case requestTooLarge(bytes: Int, maxBytes: Int)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Gateway not connected."
        case .unexpectedHandshake: "Unexpected handshake sequence."
        case .unexpectedFrame: "Unexpected gateway frame."
        case let .serverRejected(message): message
        case let .missingPayloadKey(key): "Missing payload key: \(key)"
        case let .connectionClosed(message): message
        case let .requestTooLarge(bytes, maxBytes):
            "Request payload too large (\(bytes) bytes > \(maxBytes) bytes). Reduce attachment size and try again."
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
