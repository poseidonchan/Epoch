import XCTest
@testable import EpochCore

final class CodexTrajectoryAssemblerTests: XCTestCase {
    func testAssemblerBuildsTurnAndGroupsConsecutiveFamilies() throws {
        let items: [CodexThreadItem] = [
            .userMessage(
                CodexUserMessageItem(
                    type: "userMessage",
                    id: "u1",
                    content: [CodexUserInput(type: "text", text: "do it", url: nil, path: nil)]
                )
            ),
            .mcpToolCall(
                CodexMCPToolCallItem(
                    type: "mcpToolCall",
                    id: "tool-search-1",
                    server: "web",
                    tool: "web.search_query",
                    status: "completed",
                    arguments: nil,
                    result: nil,
                    error: nil,
                    durationMs: 200
                )
            ),
            .mcpToolCall(
                CodexMCPToolCallItem(
                    type: "mcpToolCall",
                    id: "tool-search-2",
                    server: "web",
                    tool: "web.search_query",
                    status: "completed",
                    arguments: nil,
                    result: nil,
                    error: nil,
                    durationMs: 150
                )
            ),
            .commandExecution(
                CodexCommandExecutionItem(
                    type: "commandExecution",
                    id: "cmd-read-1",
                    command: "cat README.md",
                    cwd: "/tmp",
                    processId: nil,
                    status: "completed",
                    aggregatedOutput: "hello",
                    exitCode: 0,
                    durationMs: 20,
                    commandActions: []
                )
            ),
            .agentMessage(
                CodexAgentMessageItem(type: "agentMessage", id: "a1", text: "final answer")
            ),
        ]

        let turns = CodexTrajectoryAssembler.assemble(from: items, isStreaming: false)
        XCTAssertEqual(turns.count, 1)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn.finalAnswerItemID, "a1")
        XCTAssertEqual(turn.finalAnswerText, "final answer")
        XCTAssertEqual(turn.trajectoryLeaves.count, 3)
        XCTAssertEqual(turn.groups.count, 2)
        XCTAssertEqual(turn.groups[0].family, .search)
        XCTAssertEqual(turn.groups[0].leaves.count, 2)
        XCTAssertEqual(turn.groups[1].family, .read)
        XCTAssertEqual(turn.groups[1].leaves.count, 1)
    }

    func testAssemblerDoesNotMergeAcrossFamilyInterruption() throws {
        let items: [CodexThreadItem] = [
            .userMessage(
                CodexUserMessageItem(
                    type: "userMessage",
                    id: "u1",
                    content: [CodexUserInput(type: "text", text: "do it", url: nil, path: nil)]
                )
            ),
            .mcpToolCall(
                CodexMCPToolCallItem(
                    type: "mcpToolCall",
                    id: "s1",
                    server: "web",
                    tool: "web.search_query",
                    status: "completed",
                    arguments: nil,
                    result: nil,
                    error: nil,
                    durationMs: nil
                )
            ),
            .commandExecution(
                CodexCommandExecutionItem(
                    type: "commandExecution",
                    id: "r1",
                    command: "cat a.txt",
                    cwd: "/tmp",
                    processId: nil,
                    status: "completed",
                    aggregatedOutput: nil,
                    exitCode: 0,
                    durationMs: nil,
                    commandActions: []
                )
            ),
            .mcpToolCall(
                CodexMCPToolCallItem(
                    type: "mcpToolCall",
                    id: "s2",
                    server: "web",
                    tool: "web.search_query",
                    status: "completed",
                    arguments: nil,
                    result: nil,
                    error: nil,
                    durationMs: nil
                )
            ),
            .agentMessage(
                CodexAgentMessageItem(type: "agentMessage", id: "a1", text: "done")
            ),
        ]

        let turns = CodexTrajectoryAssembler.assemble(from: items, isStreaming: false)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn.groups.count, 3)
        XCTAssertEqual(turn.groups[0].family, .search)
        XCTAssertEqual(turn.groups[1].family, .read)
        XCTAssertEqual(turn.groups[2].family, .search)
    }

    func testFinalAnswerIsNotIncludedInTrajectoryLeaves() throws {
        let items: [CodexThreadItem] = [
            .userMessage(
                CodexUserMessageItem(
                    type: "userMessage",
                    id: "u1",
                    content: [CodexUserInput(type: "text", text: "q", url: nil, path: nil)]
                )
            ),
            .commandExecution(
                CodexCommandExecutionItem(
                    type: "commandExecution",
                    id: "cmd1",
                    command: "ls",
                    cwd: "/tmp",
                    processId: nil,
                    status: "completed",
                    aggregatedOutput: nil,
                    exitCode: 0,
                    durationMs: 10,
                    commandActions: []
                )
            ),
            .agentMessage(
                CodexAgentMessageItem(type: "agentMessage", id: "a_mid", text: "draft")
            ),
            .agentMessage(
                CodexAgentMessageItem(type: "agentMessage", id: "a_final", text: "final")
            ),
        ]

        let turns = CodexTrajectoryAssembler.assemble(from: items, isStreaming: false)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn.finalAnswerItemID, "a_final")
        XCTAssertEqual(turn.trajectoryLeaves.count, 2)
        XCTAssertFalse(turn.trajectoryLeaves.contains(where: { $0.id == "a_final" }))
    }

    func testTrajectoryIncludesPlanItemsEmittedAfterFinalAnswer() throws {
        let items: [CodexThreadItem] = [
            .userMessage(
                CodexUserMessageItem(
                    type: "userMessage",
                    id: "u1",
                    content: [CodexUserInput(type: "text", text: "q", url: nil, path: nil)]
                )
            ),
            .agentMessage(
                CodexAgentMessageItem(type: "agentMessage", id: "a_final", text: "final")
            ),
            .plan(
                CodexPlanItem(
                    type: "plan",
                    id: "p1",
                    text: """
                    - Step A
                    - Step B
                    - Step C
                    """
                )
            ),
        ]

        let turns = CodexTrajectoryAssembler.assemble(from: items, isStreaming: false)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn.finalAnswerItemID, "a_final")
        XCTAssertFalse(turn.trajectoryLeaves.contains(where: { $0.id == "a_final" }))
        XCTAssertTrue(turn.trajectoryLeaves.contains(where: { $0.id == "p1" }))

        let proposed = CodexProposedPlanExtractor.extract(from: turn.trajectoryLeaves.map(\.item), allowHeuristicFallback: false)
        XCTAssertEqual(proposed, "- Step A\n- Step B\n- Step C")
    }

    func testReasoningUnknownSetsThinkingFlagAndIsNotLeaf() throws {
        let items: [CodexThreadItem] = [
            .userMessage(
                CodexUserMessageItem(
                    type: "userMessage",
                    id: "u1",
                    content: [CodexUserInput(type: "text", text: "q", url: nil, path: nil)]
                )
            ),
            .unknown(
                makeUnknownItem(type: "reasoning", id: "reason-1", payload: ["text": .string("internal chain of thought")])
            ),
            .agentMessage(
                CodexAgentMessageItem(type: "agentMessage", id: "a1", text: "final")
            ),
        ]

        let turns = CodexTrajectoryAssembler.assemble(from: items, isStreaming: false)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertTrue(turn.hasThinkingStatus)
        XCTAssertTrue(turn.trajectoryLeaves.isEmpty)
    }

    func testNoTrajectorySummaryWhenNoLeavesBeforeFinalAnswer() throws {
        let items: [CodexThreadItem] = [
            .userMessage(
                CodexUserMessageItem(
                    type: "userMessage",
                    id: "u1",
                    content: [CodexUserInput(type: "text", text: "q", url: nil, path: nil)]
                )
            ),
            .agentMessage(
                CodexAgentMessageItem(type: "agentMessage", id: "a1", text: "final")
            ),
        ]

        let turns = CodexTrajectoryAssembler.assemble(from: items, isStreaming: false)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertFalse(turn.hasTrajectorySummary)
        XCTAssertTrue(turn.trajectoryLeaves.isEmpty)
        XCTAssertTrue(turn.groups.isEmpty)
    }

    func testWebSearchItemIsGroupedAsSearchFamily() throws {
        let items: [CodexThreadItem] = [
            .userMessage(
                CodexUserMessageItem(
                    type: "userMessage",
                    id: "u1",
                    content: [CodexUserInput(type: "text", text: "search this", url: nil, path: nil)]
                )
            ),
            .webSearch(
                CodexWebSearchItem(
                    type: "webSearch",
                    id: "ws1",
                    query: "Skogafoss weather",
                    action: .search(query: "Skogafoss weather", queries: ["Skogafoss weather"])
                )
            ),
            .agentMessage(
                CodexAgentMessageItem(type: "agentMessage", id: "a1", text: "done")
            ),
        ]

        let turns = CodexTrajectoryAssembler.assemble(from: items, isStreaming: false)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn.groups.count, 1)
        XCTAssertEqual(turn.groups.first?.family, .search)
        XCTAssertEqual(turn.groups.first?.leaves.count, 1)
        XCTAssertEqual(turn.groups.first?.leaves.first?.id, "ws1")
    }

    func testImageViewItemIsGroupedAsOtherFamily() throws {
        let items: [CodexThreadItem] = [
            .userMessage(
                CodexUserMessageItem(
                    type: "userMessage",
                    id: "u1",
                    content: [CodexUserInput(type: "text", text: "show plot", url: nil, path: nil)]
                )
            ),
            .imageView(
                CodexImageViewItem(
                    type: "imageView",
                    id: "img1",
                    path: "/Users/chan/Downloads/plot.png"
                )
            ),
            .agentMessage(
                CodexAgentMessageItem(type: "agentMessage", id: "a1", text: "done")
            ),
        ]

        let turns = CodexTrajectoryAssembler.assemble(from: items, isStreaming: false)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn.groups.count, 1)
        XCTAssertEqual(turn.groups.first?.family, .other)
        XCTAssertEqual(turn.groups.first?.leaves.count, 1)
        XCTAssertEqual(turn.groups.first?.leaves.first?.id, "img1")
    }

    func testProposedPlanParserExtractsPlanBlockAndSurroundingText() throws {
        let parsed = try XCTUnwrap(
            CodexProposedPlanParser.parse(
                from: """
                Assumptions and defaults:
                <proposed_plan>
                1. Scope tasks
                2. Implement changes
                </proposed_plan>
                Ready to proceed.
                """
            )
        )

        XCTAssertEqual(parsed.leadingText, "Assumptions and defaults:")
        XCTAssertEqual(parsed.planText, "1. Scope tasks\n2. Implement changes")
        XCTAssertEqual(parsed.trailingText, "Ready to proceed.")
    }

    func testProposedPlanParserReturnsNilWhenFenceIsIncomplete() {
        XCTAssertNil(
            CodexProposedPlanParser.parse(
                from: """
                Intro text
                <proposed_plan>
                - Missing closing fence
                """
            )
        )
    }

    private func makeUnknownItem(type: String, id: String, payload: [String: JSONValue]) -> CodexUnknownItem {
        var object = payload
        object["type"] = .string(type)
        object["id"] = .string(id)
        let data = try! JSONEncoder().encode(JSONValue.object(object))
        return try! JSONDecoder().decode(CodexUnknownItem.self, from: data)
    }
}
