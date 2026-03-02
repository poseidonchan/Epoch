import XCTest
@testable import EpochCore

@MainActor
final class AppStoreRunningCommandShelfEligibilityTests: XCTestCase {
    func testCommandRequiresTenSecondsWithoutOutputBeforeQualifying() {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thread_running_eligibility"
        let turnID = "turn_running_eligibility"
        let commandID = "cmd_long_running"

        store.projects = [Project(id: projectID, name: "Running Eligibility Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Running Eligibility Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexThreadBySession[sessionID] = threadID
        store.codexSessionByThread[threadID] = sessionID

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "item/started",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "item": .object([
                        "type": .string("commandExecution"),
                        "id": .string(commandID),
                        "command": .string("sleep 30"),
                        "cwd": .string("/tmp"),
                        "processId": .null,
                        "status": .string("in_progress"),
                        "aggregatedOutput": .null,
                        "exitCode": .null,
                        "durationMs": .null,
                        "commandActions": .array([]),
                    ]),
                ])
            )
        )

        let tooEarly = store.codexRunningCommandsEligibleForShelf(
            sessionID: sessionID,
            now: Date().addingTimeInterval(9.0)
        )
        XCTAssertTrue(tooEarly.isEmpty)

        let eligible = store.codexRunningCommandsEligibleForShelf(
            sessionID: sessionID,
            now: Date().addingTimeInterval(11.0)
        )
        XCTAssertEqual(eligible.map(\.id), [commandID])
    }

    func testDurationMsIsPreferredForEligibility() {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()
        let commandID = "cmd_duration_driven"

        store.codexItemsBySession[sessionID] = [
            .commandExecution(
                CodexCommandExecutionItem(
                    type: "commandExecution",
                    id: commandID,
                    command: "find . -type f",
                    cwd: "/tmp",
                    processId: nil,
                    status: "in_progress",
                    aggregatedOutput: nil,
                    exitCode: nil,
                    durationMs: 10_000,
                    commandActions: []
                )
            ),
        ]

        let eligible = store.codexRunningCommandsEligibleForShelf(
            sessionID: sessionID,
            now: Date()
        )
        XCTAssertEqual(eligible.map(\.id), [commandID])
    }

    func testOutputDeltaRemovesCommandFromEligibilityImmediately() {
        let store = AppStore(bootstrapDemo: false)
        let projectID = UUID()
        let sessionID = UUID()
        let threadID = "thread_output_delta"
        let turnID = "turn_output_delta"
        let commandID = "cmd_output_delta"

        store.projects = [Project(id: projectID, name: "Running Output Project")]
        store.sessionsByProject[projectID] = [
            Session(
                id: sessionID,
                projectID: projectID,
                title: "Running Output Session",
                backendEngine: "codex-app-server",
                codexThreadId: threadID
            ),
        ]
        store.codexThreadBySession[sessionID] = threadID
        store.codexSessionByThread[threadID] = sessionID

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "item/started",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "item": .object([
                        "type": .string("commandExecution"),
                        "id": .string(commandID),
                        "command": .string("find /tmp -name '*.log'"),
                        "cwd": .string("/tmp"),
                        "processId": .null,
                        "status": .string("in_progress"),
                        "aggregatedOutput": .null,
                        "exitCode": .null,
                        "durationMs": .null,
                        "commandActions": .array([]),
                    ]),
                ])
            )
        )

        let beforeDelta = store.codexRunningCommandsEligibleForShelf(
            sessionID: sessionID,
            now: Date().addingTimeInterval(11.0)
        )
        XCTAssertEqual(beforeDelta.map(\.id), [commandID])

        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "item/commandExecution/outputDelta",
                params: .object([
                    "threadId": .string(threadID),
                    "turnId": .string(turnID),
                    "itemId": .string(commandID),
                    "delta": .string("first output line"),
                ])
            )
        )

        let afterDelta = store.codexRunningCommandsEligibleForShelf(
            sessionID: sessionID,
            now: Date().addingTimeInterval(12.0)
        )
        XCTAssertTrue(afterDelta.isEmpty)
    }
}
