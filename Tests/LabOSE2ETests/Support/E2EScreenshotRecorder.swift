import Foundation
import XCTest

@MainActor
final class E2EScreenshotRecorder {
    private let testCase: XCTestCase
    private let artifactsDirectory: URL

    init(testCase: XCTestCase, artifactsDirectory: URL) {
        self.testCase = testCase
        self.artifactsDirectory = artifactsDirectory
    }

    @discardableResult
    func capture(stepName: String, status: String) -> URL? {
        let screenshot = XCUIScreen.main.screenshot()
        let timestamp = Self.timestampFormatter.string(from: Date())
        let fileName = "\(timestamp)-\(E2EPaths.sanitizePathComponent(stepName))-[\(status)].png"
        let fileURL = artifactsDirectory.appendingPathComponent(fileName, isDirectory: false)

        do {
            try screenshot.pngRepresentation.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }

        let attachment = XCTAttachment(image: screenshot.image)
        attachment.name = "\(stepName) [\(status)]"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)

        return fileURL
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}
