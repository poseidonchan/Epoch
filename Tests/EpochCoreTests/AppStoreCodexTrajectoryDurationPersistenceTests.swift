import XCTest
@testable import EpochCore

@MainActor
final class AppStoreCodexTrajectoryDurationPersistenceTests: XCTestCase {
    func testCodexTrajectoryDurationMigratesWhenLocalEchoIsReplaced() {
        let suiteName = "EpochCoreTests.CodexTrajectoryDuration.LocalEchoMigration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Failed to create suite-backed defaults.")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppStore(bootstrapDemo: false, userDefaults: defaults)
        let sessionID = UUID()

        let localTurnID = "\(AppStore.codexLocalUserItemPrefix)echo-1"
        let remoteTurnID = "item_user_server"
        let durationMs = 1_234

        store.codexItemsBySession[sessionID] = [
            .userMessage(
                CodexUserMessageItem(
                    type: "userMessage",
                    id: localTurnID,
                    content: [CodexUserInput(type: "text", text: "hello", url: nil, path: nil)]
                )
            ),
        ]
        store.setCodexTrajectoryDuration(sessionID: sessionID, turnID: localTurnID, durationMs: durationMs)

        let incomingItem: JSONValue = .object([
            "type": .string("userMessage"),
            "id": .string(remoteTurnID),
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("hello"),
                ]),
            ]),
        ])
        store._receiveCodexNotificationForTesting(
            CodexRPCNotification(
                method: "item/started",
                params: .object([
                    "sessionId": .string(sessionID.uuidString),
                    "item": incomingItem,
                ])
            )
        )

        XCTAssertEqual(store.codexTrajectoryDuration(sessionID: sessionID, turnID: remoteTurnID), durationMs)
        XCTAssertNil(store.codexTrajectoryDuration(sessionID: sessionID, turnID: localTurnID))
    }

    func testCodexTrajectoryDurationPersistsAcrossStoreRecreate() {
        let suiteName = "EpochCoreTests.CodexTrajectoryDuration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Failed to create suite-backed defaults.")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sessionID = UUID()
        let turnID = "turn-1"

        let first = AppStore(bootstrapDemo: false, userDefaults: defaults)
        first.setCodexTrajectoryDuration(sessionID: sessionID, turnID: turnID, durationMs: 42_000)

        let second = AppStore(bootstrapDemo: false, userDefaults: defaults)
        XCTAssertEqual(second.codexTrajectoryDuration(sessionID: sessionID, turnID: turnID), 42_000)
    }

    func testRemovingSessionClearsCodexTrajectoryDurations() {
        let suiteName = "EpochCoreTests.CodexTrajectoryDuration.SessionCleanup.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Failed to create suite-backed defaults.")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppStore(bootstrapDemo: false, userDefaults: defaults)
        let projectID = UUID()
        let sessionID = UUID()
        let turnID = "turn-cleanup-session"

        store.projects = [Project(id: projectID, name: "Cleanup Project")]
        store.sessionsByProject[projectID] = [Session(id: sessionID, projectID: projectID, title: "Cleanup Session")]

        store.setCodexTrajectoryDuration(sessionID: sessionID, turnID: turnID, durationMs: 1_337)
        XCTAssertEqual(store.codexTrajectoryDuration(sessionID: sessionID, turnID: turnID), 1_337)

        store.projectService.removeSessionLocally(projectID: projectID, sessionID: sessionID)
        XCTAssertNil(store.codexTrajectoryDuration(sessionID: sessionID, turnID: turnID))

        let reloaded = AppStore(bootstrapDemo: false, userDefaults: defaults)
        XCTAssertNil(reloaded.codexTrajectoryDuration(sessionID: sessionID, turnID: turnID))
    }

    func testRemovingProjectClearsCodexTrajectoryDurationsForAllSessions() {
        let suiteName = "EpochCoreTests.CodexTrajectoryDuration.ProjectCleanup.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Failed to create suite-backed defaults.")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppStore(bootstrapDemo: false, userDefaults: defaults)
        let projectID = UUID()
        let sessionA = UUID()
        let sessionB = UUID()

        store.projects = [Project(id: projectID, name: "Cleanup Project")]
        store.sessionsByProject[projectID] = [
            Session(id: sessionA, projectID: projectID, title: "A"),
            Session(id: sessionB, projectID: projectID, title: "B"),
        ]

        store.setCodexTrajectoryDuration(sessionID: sessionA, turnID: "turn-a", durationMs: 4_200)
        store.setCodexTrajectoryDuration(sessionID: sessionB, turnID: "turn-b", durationMs: 5_200)

        store.projectService.removeProjectLocally(projectID: projectID)

        XCTAssertNil(store.codexTrajectoryDuration(sessionID: sessionA, turnID: "turn-a"))
        XCTAssertNil(store.codexTrajectoryDuration(sessionID: sessionB, turnID: "turn-b"))

        let reloaded = AppStore(bootstrapDemo: false, userDefaults: defaults)
        XCTAssertNil(reloaded.codexTrajectoryDuration(sessionID: sessionA, turnID: "turn-a"))
        XCTAssertNil(reloaded.codexTrajectoryDuration(sessionID: sessionB, turnID: "turn-b"))
    }
}
