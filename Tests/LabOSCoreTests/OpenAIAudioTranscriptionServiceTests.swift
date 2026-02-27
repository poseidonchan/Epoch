import Foundation
import XCTest
@testable import LabOSCore

final class OpenAIAudioTranscriptionServiceTests: XCTestCase {
    func testTranscribeBuildsMultipartRequestWithExpectedFields() async throws {
        let fileURL = try makeTempAudioFile(name: "sample.m4a", contents: "audio-sample")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let httpClient = MockHTTPDataClient()
        httpClient.responses = [
            .success(data: Data("transcribed text".utf8), statusCode: 200),
        ]
        let chunker = StubAudioChunker(urls: [fileURL])
        let service = OpenAIAudioTranscriptionService(
            baseURL: URL(string: "https://api.openai.com")!,
            httpClient: httpClient,
            chunker: chunker,
            maxChunkByteCount: 1_024
        )

        let output = try await service.transcribe(
            audioFileURL: fileURL,
            apiKey: "sk-test",
            model: .gpt4oMiniTranscribe,
            prompt: "normalize spoken text"
        )

        XCTAssertEqual(output, "transcribed text")
        XCTAssertEqual(httpClient.requests.count, 1)
        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")

        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.contains("multipart/form-data; boundary="))

        let bodyData = try XCTUnwrap(request.httpBody)
        let bodyText = String(decoding: bodyData, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("name=\"model\""))
        XCTAssertTrue(bodyText.contains("gpt-4o-mini-transcribe"))
        XCTAssertTrue(bodyText.contains("name=\"response_format\""))
        XCTAssertTrue(bodyText.contains("text"))
        XCTAssertTrue(bodyText.contains("name=\"prompt\""))
        XCTAssertTrue(bodyText.contains("normalize spoken text"))
        XCTAssertTrue(bodyText.contains("name=\"file\"; filename=\"sample.m4a\""))
    }

    func testTranscribeUsesSelectedModelInPayload() async throws {
        let fileURL = try makeTempAudioFile(name: "model-check.m4a", contents: "model-check")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let httpClient = MockHTTPDataClient()
        httpClient.responses = [
            .success(data: Data("ok".utf8), statusCode: 200),
        ]
        let service = OpenAIAudioTranscriptionService(
            baseURL: URL(string: "https://api.openai.com")!,
            httpClient: httpClient,
            chunker: StubAudioChunker(urls: [fileURL]),
            maxChunkByteCount: 1_024
        )

        _ = try await service.transcribe(
            audioFileURL: fileURL,
            apiKey: "sk-test",
            model: .gpt4oTranscribe,
            prompt: "prompt"
        )

        let request = try XCTUnwrap(httpClient.requests.first)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("gpt-4o-transcribe"))
    }

    func testTranscribeConcatenatesChunkTranscriptionsInOrder() async throws {
        let first = try makeTempAudioFile(name: "part-1.m4a", contents: "chunk-1")
        let second = try makeTempAudioFile(name: "part-2.m4a", contents: "chunk-2")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let httpClient = MockHTTPDataClient()
        httpClient.responses = [
            .success(data: Data("first part".utf8), statusCode: 200),
            .success(data: Data("second part".utf8), statusCode: 200),
        ]
        let service = OpenAIAudioTranscriptionService(
            baseURL: URL(string: "https://api.openai.com")!,
            httpClient: httpClient,
            chunker: StubAudioChunker(urls: [first, second]),
            maxChunkByteCount: 1
        )

        let output = try await service.transcribe(
            audioFileURL: first,
            apiKey: "sk-test",
            model: .gpt4oMiniTranscribe,
            prompt: "prompt"
        )

        XCTAssertEqual(output, "first part\nsecond part")
        XCTAssertEqual(httpClient.requests.count, 2)
        let firstBody = String(decoding: try XCTUnwrap(httpClient.requests[0].httpBody), as: UTF8.self)
        let secondBody = String(decoding: try XCTUnwrap(httpClient.requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains("filename=\"part-1.m4a\""))
        XCTAssertTrue(secondBody.contains("filename=\"part-2.m4a\""))
    }

    func testTranscribeMapsUnauthorizedResponseToDomainError() async throws {
        let fileURL = try makeTempAudioFile(name: "unauthorized.m4a", contents: "unauthorized")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let httpClient = MockHTTPDataClient()
        httpClient.responses = [
            .success(data: Data("{\"error\":{\"message\":\"bad key\"}}".utf8), statusCode: 401),
        ]
        let service = OpenAIAudioTranscriptionService(
            baseURL: URL(string: "https://api.openai.com")!,
            httpClient: httpClient,
            chunker: StubAudioChunker(urls: [fileURL]),
            maxChunkByteCount: 1_024
        )

        do {
            _ = try await service.transcribe(
                audioFileURL: fileURL,
                apiKey: "sk-test",
                model: .gpt4oMiniTranscribe,
                prompt: "prompt"
            )
            XCTFail("Expected transcription to fail with unauthorized error")
        } catch let error as OpenAIAudioTranscriptionError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeTempAudioFile(name: String, contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.data(using: .utf8)?.write(to: url)
        return url
    }
}

private final class MockHTTPDataClient: OpenAIHTTPDataClient {
    struct StubbedResponse {
        var data: Data
        var statusCode: Int

        static func success(data: Data, statusCode: Int) -> StubbedResponse {
            StubbedResponse(data: data, statusCode: statusCode)
        }
    }

    var responses: [StubbedResponse] = []
    var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw NSError(domain: "OpenAIAudioTranscriptionServiceTests", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No stubbed response available",
            ])
        }
        let next = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
            statusCode: next.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (next.data, response)
    }
}

private struct StubAudioChunker: OpenAIAudioChunking {
    var urls: [URL]

    func chunkAudioIfNeeded(fileURL _: URL, maxChunkByteCount _: Int) async throws -> [URL] {
        urls
    }
}
