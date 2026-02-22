#if os(iOS)
import LabOSCore
import SwiftUI

struct PlanConfirmationSheet: View {
    let plan: ExecutionPlan
    let judgment: JudgmentPrompt?
    let onRun: (JudgmentResponses?) -> Void
    let onCancel: () -> Void

    @State private var selectedOptionsByQuestionID: [String: String] = [:]
    @State private var freeformByQuestionID: [String: String] = [:]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    if let judgment, !judgment.questions.isEmpty {
                        Section("Judgment") {
                            ForEach(judgment.questions, id: \.id) { q in
                                VStack(alignment: .leading, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(q.header)
                                            .font(.subheadline.weight(.semibold))
                                        Text(q.question)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(q.options, id: \.label) { option in
                                            let selected = selectedOptionsByQuestionID[q.id] == option.label
                                            Button {
                                                selectedOptionsByQuestionID[q.id] = option.label
                                            } label: {
                                                HStack(alignment: .top, spacing: 10) {
                                                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                                        .foregroundStyle(selected ? .blue : .secondary)

                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(option.label)
                                                            .font(.subheadline.weight(.semibold))
                                                            .foregroundStyle(.primary)

                                                        Text(option.description)
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                            .fixedSize(horizontal: false, vertical: true)
                                                    }

                                                    Spacer(minLength: 0)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }

                                    if q.allowFreeform {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Other / note")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)

                                            TextEditor(text: Binding(
                                                get: { freeformByQuestionID[q.id] ?? "" },
                                                set: { freeformByQuestionID[q.id] = $0 }
                                            ))
                                            .frame(minHeight: 70)
                                            .font(.body)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .strokeBorder(Color.primary.opacity(0.1))
                                            )
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    Section {
                        ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "checkmark.square")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Step \(index + 1)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Text(step.title)
                                            .font(.subheadline.weight(.semibold))
                                    }
                                }

                                Label(step.runtime.rawValue, systemImage: "hammer")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                keyValueBlock(title: "Inputs", values: step.inputs)
                                keyValueBlock(title: "Expected outputs", values: step.outputs)

                                if !step.riskFlags.isEmpty {
                                    keyValueBlock(
                                        title: "Risk flags",
                                        values: step.riskFlags.map(\.rawValue),
                                        color: .orange
                                    )
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }

                VStack(spacing: 10) {
                    Button("Run") {
                        onRun(composeJudgmentResponses())
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Cancel", role: .cancel) {
                        onCancel()
                    }
                    .buttonStyle(.bordered)

                    Button("Run step-by-step") {}
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("Proposed Plan")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.fraction(0.3), .fraction(0.7), .large])
        .presentationDragIndicator(.visible)
    }

    private func composeJudgmentResponses() -> JudgmentResponses? {
        guard let judgment else { return nil }
        let validIDs = Set(judgment.questions.map(\.id))

        var answers: [String: String] = [:]
        for (id, value) in selectedOptionsByQuestionID where validIDs.contains(id) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { answers[id] = trimmed }
        }

        var freeform: [String: String] = [:]
        for (id, value) in freeformByQuestionID where validIDs.contains(id) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { freeform[id] = trimmed }
        }

        guard !answers.isEmpty || !freeform.isEmpty else { return nil }
        return JudgmentResponses(
            answers: answers.isEmpty ? nil : answers,
            freeform: freeform.isEmpty ? nil : freeform
        )
    }

    private func keyValueBlock(title: String, values: [String], color: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if values.isEmpty {
                Text("- none")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(values, id: \.self) { value in
                    Text("- \(value)")
                        .font(.caption)
                        .foregroundStyle(color)
                }
            }
        }
    }
}
#endif
