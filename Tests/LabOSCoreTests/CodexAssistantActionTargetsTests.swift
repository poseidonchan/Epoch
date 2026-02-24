import XCTest
@testable import LabOSCore

final class CodexAssistantActionTargetsTests: XCTestCase {
    func testLatestOnlyReturnsMostRecentNonEmptyAssistantMessage() {
        let items: [CodexThreadItem] = [
            .userMessage(CodexUserMessageItem(type: "userMessage", id: "u1", content: [
                CodexUserInput(type: "text", text: "first", url: nil, path: nil),
            ])),
            .agentMessage(CodexAgentMessageItem(type: "agentMessage", id: "a1", text: "first answer")),
            .userMessage(CodexUserMessageItem(type: "userMessage", id: "u2", content: [
                CodexUserInput(type: "text", text: "second", url: nil, path: nil),
            ])),
            .agentMessage(CodexAgentMessageItem(type: "agentMessage", id: "a2_stream", text: "   ")),
            .plan(CodexPlanItem(type: "plan", id: "p1", text: "thinking")),
            .agentMessage(CodexAgentMessageItem(type: "agentMessage", id: "a2_final", text: "second answer")),
        ]

        XCTAssertEqual(CodexAssistantActionTargets.latestOnly(in: items), Set(["a2_final"]))
    }

    func testLatestOnlyReturnsEmptyWhenNoNonEmptyAssistantMessageExists() {
        let items: [CodexThreadItem] = [
            .userMessage(CodexUserMessageItem(type: "userMessage", id: "u1", content: [
                CodexUserInput(type: "text", text: "hello", url: nil, path: nil),
            ])),
            .agentMessage(CodexAgentMessageItem(type: "agentMessage", id: "a_stream", text: "\n")),
        ]

        XCTAssertTrue(CodexAssistantActionTargets.latestOnly(in: items).isEmpty)
    }

    func testLatestFinalTurnTargetUsesLatestTurnEvenWhenMessageIDsRepeat() {
        let user1 = CodexUserMessageItem(type: "userMessage", id: "u1", content: [
            CodexUserInput(type: "text", text: "first", url: nil, path: nil),
        ])
        let user2 = CodexUserMessageItem(type: "userMessage", id: "u2", content: [
            CodexUserInput(type: "text", text: "second", url: nil, path: nil),
        ])

        let turns: [CodexTrajectoryTurn] = [
            CodexTrajectoryTurn(
                id: "turn_1",
                userMessage: user1,
                hasThinkingStatus: false,
                finalAnswerItemID: "assistant_final",
                finalAnswerText: "first final",
                trajectoryLeaves: [],
                groups: [],
                isStreaming: false,
                estimatedDurationMs: nil
            ),
            CodexTrajectoryTurn(
                id: "turn_2",
                userMessage: user2,
                hasThinkingStatus: false,
                finalAnswerItemID: "assistant_final",
                finalAnswerText: "second final",
                trajectoryLeaves: [],
                groups: [],
                isStreaming: false,
                estimatedDurationMs: nil
            ),
        ]

        XCTAssertEqual(
            CodexAssistantActionTargets.latestFinalTurnTarget(in: turns),
            CodexAssistantActionTarget(turnID: "turn_2", messageID: "assistant_final")
        )
    }
}
