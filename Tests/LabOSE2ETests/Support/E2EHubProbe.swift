import Foundation
import LabOSCore

@MainActor
final class E2EHubProbe {
    private let wsURL: URL
    private let token: String
    private let gatewayClient: GatewayClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(wsURL: URL, token: String, deviceID: UUID = UUID(), deviceName: String = "LabOS E2E") {
        self.wsURL = wsURL
        self.token = token
        gatewayClient = GatewayClient(wsURL: wsURL, token: token, deviceID: deviceID, deviceName: deviceName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func connect() async throws {
        await gatewayClient.connect()
        switch gatewayClient.connectionState {
        case .connected:
            return
        case let .failed(message):
            throw NSError(domain: "E2EHubProbe", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
        case .connecting:
            throw NSError(domain: "E2EHubProbe", code: -2, userInfo: [NSLocalizedDescriptionKey: "Gateway still connecting"])
        case .disconnected:
            throw NSError(domain: "E2EHubProbe", code: -3, userInfo: [NSLocalizedDescriptionKey: "Gateway disconnected"])
        }
    }

    func disconnect() {
        gatewayClient.disconnect()
    }

    func modelsCurrent() async throws -> ModelsCurrentResponse {
        struct EmptyParams: Encodable {}
        let response = try await gatewayClient.request(method: "models.current", params: EmptyParams())
        return try decodePayloadObject(response.payload)
    }

    func listProjects() async throws -> [Project] {
        struct EmptyParams: Encodable {}
        let response = try await gatewayClient.request(method: "projects.list", params: EmptyParams())
        return try decodePayload(response.payload, key: "projects")
    }

    func listSessions(projectID: UUID, includeArchived: Bool = true) async throws -> [Session] {
        struct Params: Encodable {
            var projectId: String
            var includeArchived: Bool
        }
        let params = Params(projectId: gatewayID(projectID), includeArchived: includeArchived)
        let response = try await gatewayClient.request(method: "sessions.list", params: params)
        return try decodePayload(response.payload, key: "sessions")
    }

    func chatHistory(projectID: UUID, sessionID: UUID, limit: Int = 200) async throws -> [ChatMessage] {
        struct Params: Encodable {
            var projectId: String
            var sessionId: String
            var beforeTs: Date?
            var limit: Int
        }
        let params = Params(
            projectId: gatewayID(projectID),
            sessionId: gatewayID(sessionID),
            beforeTs: nil,
            limit: limit
        )
        let response = try await gatewayClient.request(method: "chat.history", params: params)
        let messages: [ChatMessage] = try decodePayload(response.payload, key: "messages")
        return messages.sorted { $0.createdAt < $1.createdAt }
    }

    func context(projectID: UUID, sessionID: UUID) async throws -> SessionContextState {
        struct Params: Encodable {
            var projectId: String
            var sessionId: String
        }
        let params = Params(projectId: gatewayID(projectID), sessionId: gatewayID(sessionID))
        let response = try await gatewayClient.request(method: "sessions.context.get", params: params)
        return try decodePayload(response.payload, key: "context")
    }

    func listArtifacts(projectID: UUID, prefix: String? = nil) async throws -> [Artifact] {
        struct Params: Encodable {
            var projectId: String
            var prefix: String?
        }
        let params = Params(projectId: gatewayID(projectID), prefix: prefix)
        let response = try await gatewayClient.request(method: "artifacts.list", params: params)
        return try decodePayload(response.payload, key: "artifacts")
    }

    func uploadProjectFile(
        projectID: UUID,
        fileName: String,
        data: Data,
        mimeType: String = "application/octet-stream"
    ) async throws -> String {
        guard let httpBase = httpBaseURL() else {
            throw NSError(domain: "E2EHubProbe", code: -20, userInfo: [NSLocalizedDescriptionKey: "Unable to derive HTTP base URL from \(wsURL.absoluteString)"])
        }

        let endpoint = httpBase
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(gatewayID(projectID), isDirectory: true)
            .appendingPathComponent("uploads", isDirectory: false)

        let boundary = "LabOSE2E-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(boundary: boundary, fileName: fileName, data: data, mimeType: mimeType)

        let (payload, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "E2EHubProbe", code: -21, userInfo: [NSLocalizedDescriptionKey: "Upload response was not HTTP"])
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: payload, encoding: .utf8) ?? ""
            throw NSError(
                domain: "E2EHubProbe",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Upload failed (\(http.statusCode)): \(body)"]
            )
        }

        struct UploadResponse: Decodable {
            let path: String
        }
        let decoded = try decoder.decode(UploadResponse.self, from: payload)
        return decoded.path
    }

    func localProjectDirectory(projectID: UUID) -> URL {
        E2EPaths.stateDirectory
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString.lowercased(), isDirectory: true)
    }

    private func decodePayload<T: Decodable>(_ payload: [String: JSONValue]?, key: String) throws -> T {
        guard let payload, let value = payload[key] else {
            throw NSError(domain: "E2EHubProbe", code: -10, userInfo: [NSLocalizedDescriptionKey: "Missing payload key: \(key)"])
        }
        let data = try encoder.encode(value)
        return try decoder.decode(T.self, from: data)
    }

    private func decodePayloadObject<T: Decodable>(_ payload: [String: JSONValue]?) throws -> T {
        guard let payload else {
            throw NSError(domain: "E2EHubProbe", code: -11, userInfo: [NSLocalizedDescriptionKey: "Missing payload object"])
        }
        let data = try encoder.encode(JSONValue.object(payload))
        return try decoder.decode(T.self, from: data)
    }

    private func gatewayID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private func httpBaseURL() -> URL? {
        var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false)
        switch components?.scheme?.lowercased() {
        case "ws":
            components?.scheme = "http"
        case "wss":
            components?.scheme = "https"
        default:
            return nil
        }
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    private func multipartBody(boundary: String, fileName: String, data: Data, mimeType: String) -> Data {
        var body = Data()
        let eol = "\r\n"
        let safeName = fileName.replacingOccurrences(of: "\"", with: "_")

        body.append(Data("--\(boundary)\(eol)".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\(eol)".utf8))
        body.append(Data("Content-Type: \(mimeType)\(eol)\(eol)".utf8))
        body.append(data)
        body.append(Data(eol.utf8))
        body.append(Data("--\(boundary)--\(eol)".utf8))
        return body
    }
}
