import XCTest
@testable import EpochCore

final class CodexProposedPlanExtractorTests: XCTestCase {
    func testExtractPrefersProposedPlanTagText() {
        let items: [CodexThreadItem] = [
            plan("plan_1", "- Plan item"),
            agent(
                "agent_1",
                """
                Intro
                <proposed_plan>
                - Tagged plan
                </proposed_plan>
                """
            ),
        ]

        let extracted = CodexProposedPlanExtractor.extract(from: items, allowHeuristicFallback: true)
        XCTAssertEqual(extracted, "- Tagged plan")
    }

    func testExtractFallsBackToPlanItemText() {
        let items: [CodexThreadItem] = [
            agent("agent_1", "No plan tags here."),
            plan("plan_1", "1. Scope\n2. Build\n3. Verify"),
        ]

        let extracted = CodexProposedPlanExtractor.extract(from: items, allowHeuristicFallback: true)
        XCTAssertEqual(extracted, "1. Scope\n2. Build\n3. Verify")
    }

    func testExtractUsesHeuristicWhenEnabled() {
        let items: [CodexThreadItem] = [
            agent(
                "agent_1",
                """
                - Step one
                - Step two
                - Step three
                """
            ),
        ]

        let extracted = CodexProposedPlanExtractor.extract(from: items, allowHeuristicFallback: true)
        XCTAssertEqual(extracted, "- Step one\n- Step two\n- Step three")
    }

    func testExtractDoesNotUseHeuristicWhenDisabled() {
        let items: [CodexThreadItem] = [
            agent(
                "agent_1",
                """
                - Step one
                - Step two
                - Step three
                """
            ),
        ]

        let extracted = CodexProposedPlanExtractor.extract(from: items, allowHeuristicFallback: false)
        XCTAssertNil(extracted)
    }

    func testExtractKeepsFullLongPlanText() throws {
        let raw = String(repeating: "a", count: 4_500)
        let items: [CodexThreadItem] = [
            plan("plan_1", raw),
        ]

        let extracted = CodexProposedPlanExtractor.extract(from: items, allowHeuristicFallback: true)
        let value = try XCTUnwrap(extracted)
        XCTAssertEqual(value, raw)
    }

    private func agent(_ id: String, _ text: String) -> CodexThreadItem {
        .agentMessage(
            CodexAgentMessageItem(
                type: "agentMessage",
                id: id,
                text: text
            )
        )
    }

    private func plan(_ id: String, _ text: String) -> CodexThreadItem {
        .plan(
            CodexPlanItem(
                type: "plan",
                id: id,
                text: text
            )
        )
    }
}
