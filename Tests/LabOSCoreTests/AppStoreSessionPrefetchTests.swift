import XCTest
@testable import LabOSCore

@MainActor
final class AppStoreSessionPrefetchTests: XCTestCase {
    func testSessionHistoryPrefetchCandidatesExcludeWarmAndInFlightSessions() {
        let projectID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let activeNewest = Session(
            id: UUID(),
            projectID: projectID,
            title: "Active newest",
            lifecycle: .active,
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-5)
        )
        let activeWarm = Session(
            id: UUID(),
            projectID: projectID,
            title: "Active warm",
            lifecycle: .active,
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now.addingTimeInterval(-10)
        )
        let activeInFlight = Session(
            id: UUID(),
            projectID: projectID,
            title: "Active in-flight",
            lifecycle: .active,
            createdAt: now.addingTimeInterval(-240),
            updatedAt: now.addingTimeInterval(-15)
        )
        let archived = Session(
            id: UUID(),
            projectID: projectID,
            title: "Archived candidate",
            lifecycle: .archived,
            createdAt: now.addingTimeInterval(-300),
            updatedAt: now.addingTimeInterval(-20)
        )

        let candidates = AppStore.sessionHistoryPrefetchCandidates(
            sessions: [archived, activeWarm, activeInFlight, activeNewest],
            activeSessionID: nil,
            loadedMessageSessionIDs: [activeWarm.id],
            inFlightSessionIDs: [activeInFlight.id],
            lastFetchedAtBySession: [:],
            now: now,
            cooldown: 45
        )

        XCTAssertEqual(candidates, [activeNewest.id, archived.id])
    }

    func testSessionHistoryPrefetchCandidatesRespectCooldownAndActiveSessionExclusion() {
        let projectID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_001_000)

        let activeOpenSession = Session(
            id: UUID(),
            projectID: projectID,
            title: "Open session",
            lifecycle: .active,
            createdAt: now.addingTimeInterval(-90),
            updatedAt: now.addingTimeInterval(-5)
        )
        let activeRecentlyFetched = Session(
            id: UUID(),
            projectID: projectID,
            title: "Recently fetched",
            lifecycle: .active,
            createdAt: now.addingTimeInterval(-180),
            updatedAt: now.addingTimeInterval(-10)
        )
        let activeStaleFetch = Session(
            id: UUID(),
            projectID: projectID,
            title: "Stale fetch",
            lifecycle: .active,
            createdAt: now.addingTimeInterval(-240),
            updatedAt: now.addingTimeInterval(-20)
        )

        let candidates = AppStore.sessionHistoryPrefetchCandidates(
            sessions: [activeStaleFetch, activeRecentlyFetched, activeOpenSession],
            activeSessionID: activeOpenSession.id,
            loadedMessageSessionIDs: [],
            inFlightSessionIDs: [],
            lastFetchedAtBySession: [
                activeRecentlyFetched.id: now.addingTimeInterval(-12),
                activeStaleFetch.id: now.addingTimeInterval(-90),
            ],
            now: now,
            cooldown: 45
        )

        XCTAssertEqual(candidates, [activeStaleFetch.id])
    }

    func testShouldSkipSessionHistoryRefreshUsesTriggerSpecificFreshnessRules() {
        let now = Date(timeIntervalSince1970: 1_700_002_000)

        // Interactive: when we already have local messages and just prefetched, opening the
        // session should not immediately refetch and repaint the thread.
        XCTAssertTrue(
            AppStore.shouldSkipSessionHistoryRefresh(
                trigger: .interactive,
                hasInFlightRequest: false,
                hasLocalMessages: true,
                lastFetchedAt: now.addingTimeInterval(-1),
                now: now,
                prefetchCooldown: 45,
                interactiveFreshnessWindow: 8
            )
        )

        // Interactive: if there are no local messages yet, we still need to fetch.
        XCTAssertFalse(
            AppStore.shouldSkipSessionHistoryRefresh(
                trigger: .interactive,
                hasInFlightRequest: false,
                hasLocalMessages: false,
                lastFetchedAt: now.addingTimeInterval(-1),
                now: now,
                prefetchCooldown: 45,
                interactiveFreshnessWindow: 8
            )
        )

        // Prefetch: respect the longer cooldown window.
        XCTAssertTrue(
            AppStore.shouldSkipSessionHistoryRefresh(
                trigger: .prefetch,
                hasInFlightRequest: false,
                hasLocalMessages: false,
                lastFetchedAt: now.addingTimeInterval(-10),
                now: now,
                prefetchCooldown: 45,
                interactiveFreshnessWindow: 8
            )
        )
    }
}
