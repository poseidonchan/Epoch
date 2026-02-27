import Foundation

/// Pure helpers for translating Codex prompt UI state into a tool response payload.
///
/// Key behaviors:
/// - For questions marked `isOther == true` (Codex-style "Other"), a non-empty freeform response is valid even when options exist.
/// - Freeform answers are sent as the typed text only (no synthetic labels).
/// - Implement-confirmation prompts remain option-only (no freeform acceptance).
public enum CodexPromptAnswerBuilder {
    private static let planImplementationDecisionQuestionID = "labos_plan_implementation_decision"

    private static func normalizedKind(_ raw: String?) -> String {
        (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func isImplementConfirmation(promptKind: String?, questionID: String) -> Bool {
        let kind = normalizedKind(promptKind)
        if kind == "implement_confirmation" { return true }
        return questionID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == planImplementationDecisionQuestionID
    }

    public static func allowsFreeform(
        promptKind: String?,
        question: CodexPromptQuestion,
        selectedOptionID: String?
    ) -> Bool {
        if isImplementConfirmation(promptKind: promptKind, questionID: question.id) { return false }
        if question.isOther { return true }
        if question.options.isEmpty { return true }

        if let selectedOptionID,
           let selected = question.options.first(where: { $0.id == selectedOptionID }),
           selected.isOther {
            return true
        }

        return false
    }

    public static func answer(
        promptKind: String?,
        question: CodexPromptQuestion,
        selectedOptionID: String?,
        freeformText: String?
    ) -> [String]? {
        let typed = (freeformText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let freeformAllowed = allowsFreeform(promptKind: promptKind, question: question, selectedOptionID: selectedOptionID)

        if freeformAllowed, !typed.isEmpty {
            // Freeform is authoritative; do not include synthetic labels.
            return [typed]
        }

        if let selectedOptionID,
           let selected = question.options.first(where: { $0.id == selectedOptionID }) {
            if selected.isOther {
                // Explicit "Other" option selected but no typed text.
                return nil
            }
            let label = selected.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? nil : [label]
        }

        if question.options.isEmpty {
            return typed.isEmpty ? nil : [typed]
        }

        return nil
    }

    public static func answerMap(
        promptKind: String?,
        questions: [CodexPromptQuestion],
        selectedOptionIDByQuestionID: [String: String],
        freeformByQuestionID: [String: String]
    ) -> [String: [String]]? {
        guard !questions.isEmpty else { return nil }

        var answers: [String: [String]] = [:]
        for question in questions {
            let selected = selectedOptionIDByQuestionID[question.id]
            let freeform = freeformByQuestionID[question.id]
            guard let answer = answer(
                promptKind: promptKind,
                question: question,
                selectedOptionID: selected,
                freeformText: freeform
            ) else {
                return nil
            }
            answers[question.id] = answer
        }

        return answers.isEmpty ? nil : answers
    }
}

