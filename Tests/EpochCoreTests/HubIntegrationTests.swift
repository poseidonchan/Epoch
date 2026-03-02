import Foundation
import XCTest
@testable import EpochCore

final class HubIntegrationTests: XCTestCase {
    private func loadLocalHubToken() -> String? {
        // Local dev convenience only. This test is skipped unless EPOCH_HUB_INTEGRATION=1.
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".epoch/config.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (json["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "Epoch.HubIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @MainActor
    func testCreateSessionRecoversForLocalOnlyProjectWhenGatewayConfigured() async throws {
        guard ProcessInfo.processInfo.environment["EPOCH_HUB_INTEGRATION"] == "1" else {
            throw XCTSkip("Set EPOCH_HUB_INTEGRATION=1 to run Hub integration tests.")
        }

        guard let token = loadLocalHubToken(), !token.isEmpty else {
            throw XCTSkip("Missing ~/.epoch/config.json token; cannot run integration test.")
        }

        let defaults = makeIsolatedDefaults()
        let store = AppStore(backend: MockBackendClient(), bootstrapDemo: false, userDefaults: defaults)

        // 1) Create a local-only project (no gateway configured yet).
        guard let localProject = await store.createProject(name: "Integration Local Only") else {
            XCTFail("Expected local project creation to succeed.")
            return
        }

        // 2) Configure gateway, but do not call connectGateway() explicitly (mirrors Project-page send).
        store.saveGatewaySettings(wsURLString: "ws://127.0.0.1:8787/ws", token: token)

        // 3) Creating a session should recover by creating/mapping a remote project by name.
        let session = await store.createSession(projectID: localProject.id, title: "Hello")
        XCTAssertNotNil(session, "Expected createSession to recover and succeed once gateway is configured.")
    }
}
