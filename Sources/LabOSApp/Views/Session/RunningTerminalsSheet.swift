#if os(iOS)
import LabOSCore
import SwiftUI

struct RunningTerminalsSheet: View {
    let sessionID: UUID

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private var runningCommands: [CodexCommandExecutionItem] {
        store.codexItems(for: sessionID).compactMap { item in
            guard case let .commandExecution(command) = item else { return nil }
            let normalized = command.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "inprogress" || normalized == "in_progress" else { return nil }
            return command
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if runningCommands.isEmpty {
                    ContentUnavailableView("No running terminals", systemImage: "terminal")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(runningCommands, id: \.id) { command in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(command.command)
                                        .font(.system(.subheadline, design: .monospaced))
                                        .foregroundStyle(.primary)

                                    Text(command.cwd)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    if let output = command.aggregatedOutput?.trimmingCharacters(in: .whitespacesAndNewlines),
                                       !output.isEmpty {
                                        Text(output)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(10)
                                            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    } else {
                                        Text("Waiting for output...")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color(.secondarySystemBackground))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.06))
                                )
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Running terminals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif

