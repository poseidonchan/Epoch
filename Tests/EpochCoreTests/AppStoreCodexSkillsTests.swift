import XCTest
@testable import EpochCore

@MainActor
final class AppStoreCodexSkillsTests: XCTestCase {
    func testRefreshCodexSkillsDecodesSkillsArrayFromSkillsKey() async throws {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()

        store.codexRequestOverrideForTests = { method, _ in
            XCTAssertEqual(method, "skills/list")
            return CodexRPCResponse(
                id: .string("req_skills_1"),
                result: .object([
                    "skills": .array([
                        .object([
                            "cwd": .string("/tmp/workspace"),
                            "errors": .array([]),
                            "skills": .array([
                                .object([
                                    "name": .string("brainstorming"),
                                    "path": .string("/tmp/skills/brainstorming/SKILL.md"),
                                    "scope": .string("Personal"),
                                    "short_description": .string("Use before creative work"),
                                    "enabled": .bool(true),
                                    "interface": .object([
                                        "display_name": .string("Brainstorming"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                error: nil
            )
        }

        store.refreshCodexSkills(sessionID: sessionID)

        try await waitUntil(timeoutSeconds: 1.0) {
            store.codexSkillsState(for: sessionID).updatedAt != nil
        }

        let state = store.codexSkillsState(for: sessionID)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.error)
        XCTAssertEqual(state.entries.count, 1)
        XCTAssertEqual(state.entries.first?.cwd, "/tmp/workspace")
        XCTAssertEqual(state.entries.first?.skills.first?.name, "brainstorming")
        XCTAssertEqual(state.entries.first?.skills.first?.interface?.displayName, "Brainstorming")
    }

    func testRefreshCodexSkillsDecodesEntriesKeyAndCamelCaseFields() async throws {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()

        store.codexRequestOverrideForTests = { _, _ in
            CodexRPCResponse(
                id: .string("req_skills_2"),
                result: .object([
                    "entries": .array([
                        .object([
                            "cwd": .string("/tmp/second"),
                            "errors": .array([]),
                            "skills": .array([
                                .object([
                                    "name": .string("dispatching-parallel-agents"),
                                    "path": .string("/tmp/skills/dispatching-parallel-agents/SKILL.md"),
                                    "scope": .string("Team"),
                                    "shortDescription": .string("Use when tasks are independent"),
                                    "interface": .object([
                                        "displayName": .string("Dispatching Parallel Agents"),
                                        "shortDescription": .string("Split independent work"),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                error: nil
            )
        }

        store.refreshCodexSkills(sessionID: sessionID)

        try await waitUntil(timeoutSeconds: 1.0) {
            !store.codexSkillsState(for: sessionID).entries.isEmpty
        }

        let state = store.codexSkillsState(for: sessionID)
        XCTAssertEqual(state.entries.count, 1)
        let skill = try XCTUnwrap(state.entries.first?.skills.first)
        XCTAssertEqual(skill.name, "dispatching-parallel-agents")
        XCTAssertEqual(skill.shortDescription, "Use when tasks are independent")
        XCTAssertEqual(skill.interface?.displayName, "Dispatching Parallel Agents")
        XCTAssertEqual(skill.interface?.shortDescription, "Split independent work")
    }

    func testRefreshCodexSkillsDecodesDataKeyFromSpecShape() async throws {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()

        store.codexRequestOverrideForTests = { _, _ in
            CodexRPCResponse(
                id: .string("req_skills_3"),
                result: .object([
                    "data": .array([
                        .object([
                            "cwd": .string("/tmp/spec-shape"),
                            "errors": .array([]),
                            "skills": .array([
                                .object([
                                    "name": .string("brainstorming"),
                                    "description": .string("Use before creative work"),
                                    "path": .string("/tmp/skills/brainstorming/SKILL.md"),
                                    "scope": .string("user"),
                                    "enabled": .bool(true),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
                error: nil
            )
        }

        store.refreshCodexSkills(sessionID: sessionID)

        try await waitUntil(timeoutSeconds: 1.0) {
            !store.codexSkillsState(for: sessionID).entries.isEmpty
        }

        let state = store.codexSkillsState(for: sessionID)
        XCTAssertEqual(state.entries.count, 1)
        XCTAssertEqual(state.entries.first?.cwd, "/tmp/spec-shape")
        XCTAssertEqual(state.entries.first?.skills.first?.name, "brainstorming")
        XCTAssertEqual(state.entries.first?.skills.first?.scope, "user")
    }

    func testRefreshCodexSkillsStoresErrorWhenRequestFails() async throws {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()

        store.codexRequestOverrideForTests = { _, _ in
            throw NSError(domain: "EpochCoreTests", code: -7, userInfo: [NSLocalizedDescriptionKey: "skills list failed"])
        }

        store.refreshCodexSkills(sessionID: sessionID)

        try await waitUntil(timeoutSeconds: 1.0) {
            let state = store.codexSkillsState(for: sessionID)
            return state.isLoading == false && state.error != nil
        }

        let state = store.codexSkillsState(for: sessionID)
        XCTAssertEqual(state.error, "skills list failed")
        XCTAssertTrue(state.entries.isEmpty)
    }

    func testRefreshCodexSkillsNormalizesLegacyMethodNotFoundError() async throws {
        let store = AppStore(bootstrapDemo: false)
        let sessionID = UUID()

        store.codexRequestOverrideForTests = { _, _ in
            throw NSError(
                domain: "EpochCoreTests",
                code: -32601,
                userInfo: [NSLocalizedDescriptionKey: "Method not found: skills/list"]
            )
        }

        store.refreshCodexSkills(sessionID: sessionID)

        try await waitUntil(timeoutSeconds: 1.0) {
            let state = store.codexSkillsState(for: sessionID)
            return state.isLoading == false && state.error != nil
        }

        let state = store.codexSkillsState(for: sessionID)
        XCTAssertEqual(state.error, "This Hub build does not support skills yet. Update Hub/Codex and retry.")
    }

    func testSkillMentionCodecParsesKnownSkillsAndLeavesUnknownText() {
        let lookup: [String: CodexSkillMentionOption] = [
            "brainstorming": .init(name: "brainstorming", displayName: "Brainstorming"),
            "systematic-debugging": .init(name: "systematic-debugging", displayName: "Systematic Debugging"),
        ]
        let raw = "Use $brainstorming then $not-found and $systematic-debugging now"

        let mentions = CodexSkillMentionCodec.parseMentions(in: raw, lookup: lookup)

        XCTAssertEqual(mentions.count, 2)
        XCTAssertEqual(mentions.map(\.token), ["$brainstorming", "$systematic-debugging"])
        XCTAssertEqual(mentions.map(\.option.name), ["brainstorming", "systematic-debugging"])
    }

    func testSkillMentionCodecSplitAndJoinRoundTripsRawText() {
        let lookup: [String: CodexSkillMentionOption] = [
            "brainstorming": .init(name: "brainstorming", displayName: "Brainstorming"),
        ]
        let raw = "Plan: $brainstorming now."

        let components = CodexSkillMentionCodec.splitComponents(in: raw, lookup: lookup)
        let reconstructed = CodexSkillMentionCodec.joinRawText(from: components)

        XCTAssertEqual(reconstructed, raw)
        XCTAssertEqual(components.count, 3)
    }

    func testSkillMentionCodecTrailingTokenDetection() {
        let token = CodexSkillMentionCodec.trailingToken(in: "Start $brainstorming")
        XCTAssertEqual(token?.query, "brainstorming")

        XCTAssertNil(CodexSkillMentionCodec.trailingToken(in: "Start $brain storming"))
        XCTAssertNil(CodexSkillMentionCodec.trailingToken(in: "No token here"))
    }

    func testSkillMentionCodecTrailingTokenHandlesWhitespaceAndInvisibles() {
        XCTAssertNil(CodexSkillMentionCodec.trailingToken(in: "Prompt ends with $ "))
        XCTAssertNil(CodexSkillMentionCodec.trailingToken(in: "Prompt ends with $\n"))
        XCTAssertNil(CodexSkillMentionCodec.trailingToken(in: "Prompt ends with $\u{FFFC}"))
    }

    func testSkillMentionCodecTrailingTokenDetectsValidTokenAtEnd() {
        let token = CodexSkillMentionCodec.trailingToken(in: "Draft with $brainstorm")
        XCTAssertEqual(token?.query, "brainstorm")
    }

    func testSkillMentionCodecReplacingTrailingTokenUsesCanonicalSkillToken() {
        let updated = CodexSkillMentionCodec.replacingTrailingToken(
            in: "Draft with $bra",
            withSkillName: "brainstorming"
        )

        XCTAssertEqual(updated, "Draft with $brainstorming ")
    }

    func testSkillMentionCodecReplacingTrailingTokenReturnsNilWithoutTrailingToken() {
        let updated = CodexSkillMentionCodec.replacingTrailingToken(
            in: "Draft with $brain storming",
            withSkillName: "brainstorming"
        )

        XCTAssertNil(updated)
    }

    private func waitUntil(
        timeoutSeconds: TimeInterval,
        pollEvery interval: TimeInterval = 0.05,
        condition: @escaping () -> Bool
    ) async throws {
        let timeoutDate = Date().addingTimeInterval(timeoutSeconds)
        while Date() < timeoutDate {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
        XCTFail("Condition timed out after \(timeoutSeconds)s")
    }
}
