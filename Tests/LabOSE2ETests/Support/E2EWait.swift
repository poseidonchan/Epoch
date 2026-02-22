import Foundation

enum E2EWaitError: LocalizedError {
    case timedOut(timeout: TimeInterval, description: String)

    var errorDescription: String? {
        switch self {
        case let .timedOut(timeout, description):
            return "Timed out after \(timeout)s waiting for \(description)"
        }
    }
}

enum E2EWait {
    static func until(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.2,
        description: String,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() <= deadline {
            if condition() {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        throw E2EWaitError.timedOut(timeout: timeout, description: description)
    }
}
