#if os(iOS)
import LabOSCore
import SwiftUI

struct QueueManagerSheet: View {
    let sessionID: UUID

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private var canInterrupt: Bool {
        store.canInterruptCodexTurn(sessionID: sessionID)
    }

    private var queuedItems: [CodexQueuedUserInputItem] {
        store.codexQueuedInputs(for: sessionID)
    }

    var body: some View {
        NavigationStack {
            List {
                if queuedItems.isEmpty {
                    Text("No queued messages.")
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(queuedItems) { item in
                        NavigationLink {
                            QueueItemDetailView(sessionID: sessionID, itemID: item.id)
                        } label: {
                            QueueRow(item: item)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if canInterrupt {
                                Button("Steer") {
                                    store.steerQueuedCodexInput(sessionID: sessionID, queueItemID: item.id)
                                }
                                .tint(.blue)
                                .disabled(item.status == .sending)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.removeQueuedCodexInput(sessionID: sessionID, queueItemID: item.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onMove { from, to in
                        store.moveCodexQueuedInputs(sessionID: sessionID, from: from, to: to)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Queued messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    EditButton()
                        .disabled(queuedItems.count < 2)
                }
            }
        }
    }

    private struct QueueRow: View {
        let item: CodexQueuedUserInputItem

        private var title: String {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
            if !item.attachments.isEmpty { return "Attachments only" }
            return "(empty)"
        }

        private var subtitle: String? {
            if item.attachments.isEmpty { return nil }
            let names = item.attachments.map { $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if names.isEmpty {
                return "\(item.attachments.count) attachment(s)"
            }
            let joined = names.prefix(3).joined(separator: ", ")
            return item.attachments.count > 3 ? "\(joined) +\(item.attachments.count - 3)" : joined
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    statusChip
                }

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if item.status == .failed, let error = item.error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
            .accessibilityIdentifier("session.shelf.queue.row.\(item.id.uuidString.lowercased())")
        }

        private var statusChip: some View {
            let (label, tint): (String, Color) = switch item.status {
            case .queued:
                ("Queued", .secondary)
            case .sending:
                ("Sending", .blue)
            case .failed:
                ("Failed", .red)
            }

            return Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(tint.opacity(0.12))
                )
        }
    }
}
#endif
