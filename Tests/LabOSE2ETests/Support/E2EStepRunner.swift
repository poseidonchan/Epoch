import Foundation
import XCTest

struct E2EStepArtifact {
    let name: String
    let status: String
    let screenshotURL: URL?
    let logURL: URL?
}

@MainActor
final class E2EStepRunner {
    private let app: XCUIApplication
    private let artifactsDirectory: URL
    private let screenshotRecorder: E2EScreenshotRecorder
    private(set) var artifacts: [E2EStepArtifact] = []

    init(testCase: XCTestCase, app: XCUIApplication, artifactsDirectory: URL? = nil) {
        self.app = app
        let testName = String(describing: type(of: testCase))
        self.artifactsDirectory = artifactsDirectory ?? E2EPaths.artifactsDirectory(for: testName)
        screenshotRecorder = E2EScreenshotRecorder(testCase: testCase, artifactsDirectory: self.artifactsDirectory)
    }

    @discardableResult
    func step(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) throws -> E2EStepArtifact {
        let startedAt = Date()

        do {
            try body()
            let screenshotURL = screenshotRecorder.capture(stepName: name, status: "pass")
            let logURL = writeLog(stepName: name, status: "pass", startedAt: startedAt, endedAt: Date(), note: nil)
            let artifact = E2EStepArtifact(name: name, status: "pass", screenshotURL: screenshotURL, logURL: logURL)
            artifacts.append(artifact)
            return artifact
        } catch {
            let screenshotURL = screenshotRecorder.capture(stepName: name, status: "fail")
            let logURL = writeLog(
                stepName: name,
                status: "fail",
                startedAt: startedAt,
                endedAt: Date(),
                note: String(describing: error)
            )
            let artifact = E2EStepArtifact(name: name, status: "fail", screenshotURL: screenshotURL, logURL: logURL)
            artifacts.append(artifact)
            // Rethrow directly so continueAfterFailure=false can terminate without XCTest control-flow interruptions.
            throw error
        }
    }

    @discardableResult
    func stepAsync(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async throws -> E2EStepArtifact {
        let startedAt = Date()

        do {
            try await body()
            let screenshotURL = screenshotRecorder.capture(stepName: name, status: "pass")
            let logURL = writeLog(stepName: name, status: "pass", startedAt: startedAt, endedAt: Date(), note: nil)
            let artifact = E2EStepArtifact(name: name, status: "pass", screenshotURL: screenshotURL, logURL: logURL)
            artifacts.append(artifact)
            return artifact
        } catch {
            let screenshotURL = screenshotRecorder.capture(stepName: name, status: "fail")
            let logURL = writeLog(
                stepName: name,
                status: "fail",
                startedAt: startedAt,
                endedAt: Date(),
                note: String(describing: error)
            )
            let artifact = E2EStepArtifact(name: name, status: "fail", screenshotURL: screenshotURL, logURL: logURL)
            artifacts.append(artifact)
            // Rethrow directly so continueAfterFailure=false can terminate without XCTest control-flow interruptions.
            throw error
        }
    }

    func lastStepArtifactsContain(_ fragment: String) -> Bool {
        guard let last = artifacts.last else { return false }
        if last.name.contains(fragment) {
            return true
        }
        if let screenshotPath = last.screenshotURL?.path, screenshotPath.contains(fragment) {
            return true
        }
        if let logPath = last.logURL?.path, logPath.contains(fragment) {
            return true
        }
        return false
    }

    @discardableResult
    private func writeLog(
        stepName: String,
        status: String,
        startedAt: Date,
        endedAt: Date,
        note: String?
    ) -> URL? {
        let timestamp = Self.timestampFormatter.string(from: endedAt)
        let fileName = "\(timestamp)-\(E2EPaths.sanitizePathComponent(stepName)).json"
        let fileURL = artifactsDirectory.appendingPathComponent(fileName, isDirectory: false)

        let payload: [String: String] = [
            "step": stepName,
            "status": status,
            "startedAt": Self.iso8601.string(from: startedAt),
            "endedAt": Self.iso8601.string(from: endedAt),
            "durationSeconds": String(format: "%.3f", endedAt.timeIntervalSince(startedAt)),
            "appState": String(app.state.rawValue),
            "note": note ?? ""
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}
