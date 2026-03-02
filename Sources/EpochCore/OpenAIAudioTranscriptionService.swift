import AVFoundation
import Foundation

protocol OpenAIHTTPDataClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: OpenAIHTTPDataClient {}

protocol OpenAIAudioChunking {
    func chunkAudioIfNeeded(fileURL: URL, maxChunkByteCount: Int) async throws -> [URL]
}

enum OpenAIAudioTranscriptionError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case invalidResponse
    case unauthorized
    case rateLimited
    case unsupportedAudio
    case server(statusCode: Int)
    case requestFailed(statusCode: Int, message: String?)
    case emptyTranscription
    case chunkingFailed(String)
    case network(description: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is missing. Configure it in Settings."
        case .invalidResponse:
            return "OpenAI returned an invalid response."
        case .unauthorized:
            return "OpenAI API key was rejected (401)."
        case .rateLimited:
            return "OpenAI rate limit reached (429)."
        case .unsupportedAudio:
            return "Recording file is invalid or unsupported. Please retry and hold a bit longer before release."
        case let .server(statusCode):
            return "OpenAI server error (\(statusCode))."
        case let .requestFailed(statusCode, message):
            if let message, !message.isEmpty {
                return "OpenAI request failed (\(statusCode)): \(message)"
            }
            return "OpenAI request failed (\(statusCode))."
        case .emptyTranscription:
            return "OpenAI returned empty transcription text."
        case let .chunkingFailed(message):
            return "Audio chunking failed: \(message)"
        case let .network(description):
            return "Network error during transcription: \(description)"
        }
    }
}

struct OpenAIAudioTranscriptionService {
    private let baseURL: URL
    private let httpClient: OpenAIHTTPDataClient
    private let chunker: OpenAIAudioChunking
    private let maxChunkByteCount: Int
    private let fileManager: FileManager

    init(
        baseURL: URL = URL(string: "https://api.openai.com")!,
        httpClient: OpenAIHTTPDataClient = URLSession.shared,
        chunker: OpenAIAudioChunking = OpenAIAudioChunker(),
        maxChunkByteCount: Int = 25 * 1_024 * 1_024,
        fileManager: FileManager = .default
    ) {
        self.baseURL = baseURL
        self.httpClient = httpClient
        self.chunker = chunker
        self.maxChunkByteCount = max(1, maxChunkByteCount)
        self.fileManager = fileManager
    }

    func transcribe(
        audioFileURL: URL,
        apiKey: String,
        model: OpenAIVoiceTranscriptionModel,
        prompt: String
    ) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw OpenAIAudioTranscriptionError.missingAPIKey
        }

        let chunkURLs: [URL]
        do {
            chunkURLs = try await chunker.chunkAudioIfNeeded(fileURL: audioFileURL, maxChunkByteCount: maxChunkByteCount)
        } catch let error as OpenAIAudioTranscriptionError {
            throw error
        } catch {
            throw OpenAIAudioTranscriptionError.chunkingFailed(error.localizedDescription)
        }

        guard !chunkURLs.isEmpty else {
            throw OpenAIAudioTranscriptionError.chunkingFailed("No audio chunks were produced.")
        }

        defer {
            for url in chunkURLs where url.path != audioFileURL.path {
                try? fileManager.removeItem(at: url)
            }
        }

        var parts: [String] = []
        for chunkURL in chunkURLs {
            let text = try await transcribeSingleChunk(
                chunkURL: chunkURL,
                apiKey: key,
                model: model,
                prompt: prompt
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }

        guard !parts.isEmpty else {
            throw OpenAIAudioTranscriptionError.emptyTranscription
        }

        return parts.joined(separator: "\n")
    }

    private func transcribeSingleChunk(
        chunkURL: URL,
        apiKey: String,
        model: OpenAIVoiceTranscriptionModel,
        prompt: String
    ) async throws -> String {
        let endpoint = transcriptionEndpoint()
        let boundary = "epoch-\(UUID().uuidString)"
        let body = try multipartBody(
            fileURL: chunkURL,
            model: model,
            prompt: prompt,
            boundary: boundary
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response) = try await httpClient.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenAIAudioTranscriptionError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                switch httpResponse.statusCode {
                case 401:
                    throw OpenAIAudioTranscriptionError.unauthorized
                case 429:
                    throw OpenAIAudioTranscriptionError.rateLimited
                case 500 ... 599:
                    throw OpenAIAudioTranscriptionError.server(statusCode: httpResponse.statusCode)
                default:
                    let message = parseErrorMessage(from: data)
                    if httpResponse.statusCode == 400,
                       isUnsupportedAudioMessage(message) {
                        throw OpenAIAudioTranscriptionError.unsupportedAudio
                    }
                    throw OpenAIAudioTranscriptionError.requestFailed(
                        statusCode: httpResponse.statusCode,
                        message: message
                    )
                }
            }

            let parsed = parseTranscriptionText(from: data)
            guard !parsed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenAIAudioTranscriptionError.emptyTranscription
            }
            return parsed
        } catch let error as OpenAIAudioTranscriptionError {
            throw error
        } catch {
            throw OpenAIAudioTranscriptionError.network(description: error.localizedDescription)
        }
    }

    private func transcriptionEndpoint() -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL.appendingPathComponent("v1/audio/transcriptions")
        }
        var path = components.path
        if path.hasSuffix("/") {
            path.removeLast()
        }
        path += "/v1/audio/transcriptions"
        components.path = path
        return components.url ?? baseURL.appendingPathComponent("v1/audio/transcriptions")
    }

    private func multipartBody(
        fileURL: URL,
        model: OpenAIVoiceTranscriptionModel,
        prompt: String,
        boundary: String
    ) throws -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model.rawValue)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("text\r\n")

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            append("\(trimmedPrompt)\r\n")
        }

        let fileData = try Data(contentsOf: fileURL)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        append("Content-Type: \(mimeType(for: fileURL))\r\n\r\n")
        body.append(fileData)
        append("\r\n")
        append("--\(boundary)--\r\n")
        return body
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/mp4"
        default:
            return "application/octet-stream"
        }
    }

    private func isUnsupportedAudioMessage(_ message: String?) -> Bool {
        guard let message else { return false }
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.contains("corrupt")
            || normalized.contains("unsupported")
            || normalized.contains("invalid audio")
            || normalized.contains("audio file might")
    }

    private func parseTranscriptionText(from data: Data) -> String {
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return "" }

        // When response_format=text, OpenAI returns plain text. Keep a JSON fallback for robustness.
        if text.hasPrefix("{"),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let nested = object["text"] as? String {
            return nested.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let message = object["message"] as? String {
                return message
            }
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct OpenAIAudioChunker: OpenAIAudioChunking {
    private let fileManager: FileManager = .default

    func chunkAudioIfNeeded(fileURL: URL, maxChunkByteCount: Int) async throws -> [URL] {
        let size = try fileSize(for: fileURL)
        if size <= maxChunkByteCount {
            return [fileURL]
        }

        let asset = AVURLAsset(url: fileURL)
        let durationSeconds = CMTimeGetSeconds(try await asset.load(.duration))
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw OpenAIAudioTranscriptionError.chunkingFailed("Audio duration is unavailable.")
        }

        let estimatedParts = Int(ceil(Double(size) / Double(maxChunkByteCount)))
        let partCount = max(2, estimatedParts)
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent("epoch-voice-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        var chunkURLs: [URL] = []
        chunkURLs.reserveCapacity(partCount)

        for index in 0 ..< partCount {
            let startSeconds = durationSeconds * Double(index) / Double(partCount)
            let endSeconds = durationSeconds * Double(index + 1) / Double(partCount)
            let outputURL = tempDirectory.appendingPathComponent("chunk-\(index).m4a")
            if fileManager.fileExists(atPath: outputURL.path) {
                try? fileManager.removeItem(at: outputURL)
            }

            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw OpenAIAudioTranscriptionError.chunkingFailed("Failed to create export session.")
            }
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .m4a
            exportSession.timeRange = CMTimeRange(
                start: CMTime(seconds: startSeconds, preferredTimescale: 600),
                end: CMTime(seconds: endSeconds, preferredTimescale: 600)
            )
            try await exportSession.exportAsync()

            guard fileManager.fileExists(atPath: outputURL.path) else {
                throw OpenAIAudioTranscriptionError.chunkingFailed("Chunk export produced no output file.")
            }
            chunkURLs.append(outputURL)
        }

        return chunkURLs
    }

    private func fileSize(for url: URL) throws -> Int {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            return max(0, size)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber {
            return max(0, size.intValue)
        }
        throw OpenAIAudioTranscriptionError.chunkingFailed("Unable to read audio file size.")
    }
}

private extension AVAssetExportSession {
    func exportAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            nonisolated(unsafe) let session = self
            exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: OpenAIAudioTranscriptionError.chunkingFailed(session.error?.localizedDescription ?? "Unknown export failure."))
                case .cancelled:
                    continuation.resume(throwing: OpenAIAudioTranscriptionError.chunkingFailed("Export was cancelled."))
                default:
                    continuation.resume(throwing: OpenAIAudioTranscriptionError.chunkingFailed("Export ended in unexpected state: \(session.status.rawValue)."))
                }
            }
        }
    }
}
