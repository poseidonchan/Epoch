import Foundation

public enum CodexConnectionState: Hashable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(message: String)
}

public enum CodexRPCClientError: Error {
    case notConnected
    case connectionClosed(String)
    case protocolViolation(String)
    case serverRejected(String)
}

@MainActor
public final class CodexRPCClient: ObservableObject {
    @Published public private(set) var connectionState: CodexConnectionState = .disconnected

    private let wsURL: URL
    private let token: String

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var urlSession: URLSession?

    private var pending: [CodexRequestID: CheckedContinuation<CodexRPCResponse, Error>] = [:]

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var notificationsContinuation: AsyncStream<CodexRPCNotification>.Continuation?
    public private(set) var notifications: AsyncStream<CodexRPCNotification>

    private var serverRequestsContinuation: AsyncStream<CodexRPCRequest>.Continuation?
    public private(set) var serverRequests: AsyncStream<CodexRPCRequest>

    public init(wsURL: URL, token: String) {
        self.wsURL = wsURL
        self.token = token

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        var notificationsContinuation: AsyncStream<CodexRPCNotification>.Continuation?
        notifications = AsyncStream<CodexRPCNotification> { continuation in
            notificationsContinuation = continuation
        }
        self.notificationsContinuation = notificationsContinuation

        var serverRequestsContinuation: AsyncStream<CodexRPCRequest>.Continuation?
        serverRequests = AsyncStream<CodexRPCRequest> { continuation in
            serverRequestsContinuation = continuation
        }
        self.serverRequestsContinuation = serverRequestsContinuation
    }

    deinit {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    public func connect() async {
        switch connectionState {
        case .connecting, .connected:
            return
        case .disconnected, .failed:
            break
        }

        disconnect()
        connectionState = .connecting

        let normalizedURL = codexURLWithToken(base: wsURL, token: token)
        let session = URLSession(configuration: .default)
        urlSession = session

        let task = session.webSocketTask(with: normalizedURL)
        webSocketTask = task
        task.resume()
        startReceiveLoop(task)

        do {
            let initID = CodexRequestID.string(UUID().uuidString)
            let initializeParams: [String: JSONValue] = [
                "clientInfo": .object([
                    "name": .string("LabOSApp"),
                    "version": .string("0.1.0"),
                ]),
                "capabilities": .object([
                    "experimentalApi": .bool(true),
                ]),
            ]

            _ = try await requestInternal(
                id: initID,
                method: "initialize",
                params: .object(initializeParams),
                task: task
            )

            try await sendRawMessage(CodexRPCNotification(method: "initialized", params: nil), task: task)

            connectionState = .connected
        } catch {
            connectionState = .failed(message: String(describing: error))
            failPending(error)
            receiveTask?.cancel()
            receiveTask = nil
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
        failPending(CodexRPCClientError.connectionClosed("Disconnected"))
        connectionState = .disconnected
    }

    public func request<Params: Encodable>(method: String, params: Params) async throws -> CodexRPCResponse {
        guard let task = webSocketTask else {
            throw CodexRPCClientError.notConnected
        }

        let id = CodexRequestID.string(UUID().uuidString)
        let paramsValue = try encodeAsJSONValue(params)
        return try await requestInternal(id: id, method: method, params: paramsValue, task: task)
    }

    public func respond(result: JSONValue?, for requestID: CodexRequestID) async throws {
        guard let task = webSocketTask else {
            throw CodexRPCClientError.notConnected
        }

        let response = CodexRPCResponse(id: requestID, result: result, error: nil)
        try await sendRawMessage(response, task: task)
    }

    public func respond(error: CodexRPCError, for requestID: CodexRequestID) async throws {
        guard let task = webSocketTask else {
            throw CodexRPCClientError.notConnected
        }

        let response = CodexRPCResponse(id: requestID, result: nil, error: error)
        try await sendRawMessage(response, task: task)
    }

    private func requestInternal(
        id: CodexRequestID,
        method: String,
        params: JSONValue?,
        task: URLSessionWebSocketTask
    ) async throws -> CodexRPCResponse {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CodexRPCResponse, Error>) in
            pending[id] = continuation

            Task {
                do {
                    let request = CodexRPCRequest(id: id, method: method, params: params)
                    try await sendRawMessage(request, task: task)
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let inbound = try await self.receiveOneMessage(from: task)
                    await MainActor.run {
                        self.handleInbound(inbound)
                    }
                } catch {
                    await MainActor.run {
                        self.connectionState = .failed(message: String(describing: error))
                        self.failPending(CodexRPCClientError.connectionClosed(String(describing: error)))
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

    private func handleInbound(_ inbound: CodexRPCInbound) {
        switch inbound {
        case let .response(response):
            guard let continuation = pending.removeValue(forKey: response.id) else { return }
            if let error = response.error {
                continuation.resume(throwing: CodexRPCClientError.serverRejected(error.message))
            } else {
                continuation.resume(returning: response)
            }
        case let .request(request):
            serverRequestsContinuation?.yield(request)
        case let .notification(notification):
            notificationsContinuation?.yield(notification)
        }
    }

    private func receiveOneMessage(from task: URLSessionWebSocketTask) async throws -> CodexRPCInbound {
        let wsMessage = try await task.receive()
        let data: Data

        switch wsMessage {
        case let .data(binary):
            data = binary
        case let .string(text):
            guard let utf8 = text.data(using: .utf8) else {
                throw CodexRPCClientError.protocolViolation("Received invalid UTF-8")
            }
            data = utf8
        @unknown default:
            throw CodexRPCClientError.protocolViolation("Received unknown message type")
        }

        return try Self.decodeInboundPayloadForTesting(data)
    }

    private func sendRawMessage<T: Encodable>(_ payload: T, task: URLSessionWebSocketTask) async throws {
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexRPCClientError.protocolViolation("Failed to encode outgoing message")
        }
        try await task.send(.string(text))
    }

    private func failPending(_ error: Error) {
        let active = pending
        pending.removeAll()
        for (_, continuation) in active {
            continuation.resume(throwing: error)
        }
    }

    private func encodeAsJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try encoder.encode(value)
        return try decoder.decode(JSONValue.self, from: data)
    }

    private func codexURLWithToken(base: URL, token: String) -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }

        var queryItems = components.queryItems ?? []
        let hasToken = queryItems.contains { $0.name == "token" }
        if !hasToken {
            queryItems.append(URLQueryItem(name: "token", value: token))
            components.queryItems = queryItems
        }

        return components.url ?? base
    }
}

private struct CodexMessageEnvelope: Codable {
    var id: CodexRequestID?
    var method: String?
    var params: JSONValue?
    var result: JSONValue?
    var error: CodexRPCError?
}

extension CodexRPCClient {
    nonisolated static func decodeInboundPayloadForTesting(_ data: Data) throws -> CodexRPCInbound {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(CodexMessageEnvelope.self, from: data)

        if let method = envelope.method {
            if let id = envelope.id {
                return .request(CodexRPCRequest(id: id, method: method, params: envelope.params))
            }
            return .notification(CodexRPCNotification(method: method, params: envelope.params))
        }

        guard let id = envelope.id else {
            throw CodexRPCClientError.protocolViolation("Received JSON-RPC response without id")
        }

        return .response(CodexRPCResponse(id: id, result: envelope.result, error: envelope.error))
    }

    nonisolated static func encodeResponsePayloadForTesting(_ response: CodexRPCResponse) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(response)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexRPCClientError.protocolViolation("Failed to encode response payload")
        }
        return text
    }
}
