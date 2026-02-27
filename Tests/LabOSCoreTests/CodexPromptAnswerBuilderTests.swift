import XCTest

@testable import LabOSCore

final class CodexPromptAnswerBuilderTests: XCTestCase {
    func testOtherFreeformWithOptionsReturnsTypedOnly() {
        let question = CodexPromptQuestion(
            id: "plan_theme",
            prompt: "Pick a theme",
            isOther: true,
            options: [
                CodexPromptOption(id: "space", label: "Space Mission"),
                CodexPromptOption(id: "treasure", label: "Treasure Hunt"),
            ]
        )

        let answer = CodexPromptAnswerBuilder.answer(
            promptKind: "prompt",
            question: question,
            selectedOptionID: nil,
            freeformText: "stop the test"
        )

        XCTAssertEqual(answer, ["stop the test"])
    }

    func testOtherFreeformBeatsSelectedOption() {
        let question = CodexPromptQuestion(
            id: "question_style",
            prompt: "How weird?",
            isOther: true,
            options: [
                CodexPromptOption(id: "medium", label: "Medium Weird"),
                CodexPromptOption(id: "very", label: "Very Weird"),
            ]
        )

        let answer = CodexPromptAnswerBuilder.answer(
            promptKind: "prompt",
            question: question,
            selectedOptionID: "medium",
            freeformText: "stop the test"
        )

        XCTAssertEqual(answer, ["stop the test"])
    }

    func testImplementConfirmationDoesNotAcceptFreeform() {
        let question = CodexPromptQuestion(
            id: "labos_plan_implementation_decision",
            prompt: "",
            isOther: true,
            options: [
                CodexPromptOption(id: "yes", label: "Yes, implement this plan"),
                CodexPromptOption(id: "no", label: "No, and tell Codex what to do differently"),
            ]
        )

        let answer = CodexPromptAnswerBuilder.answer(
            promptKind: "implement_confirmation",
            question: question,
            selectedOptionID: nil,
            freeformText: "stop the test"
        )

        XCTAssertNil(answer)
    }
}

