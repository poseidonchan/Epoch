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
                } else {
                    ForEach(queuedItems) { item in
                        NavigationLink {
                            QueueItemDetailView(sessionID: sessionID, itemID: item.id)
                        } label: {
                            QueueRow(item: item)
                        }
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
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if item.status == .failed, let error = item.error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .accessibilityIdentifier("session.shelf.queue.row.\(item.id.uuidString.lowercased())")
        }
    }

    private struct QueueItemDetailView: View {
        let sessionID: UUID
        let itemID: UUID

        @EnvironmentObject private var store: AppStore

        @State private var draftText: String = ""

        private var canInterrupt: Bool {
            store.canInterruptCodexTurn(sessionID: sessionID)
        }

        private var item: CodexQueuedUserInputItem? {
            store.codexQueuedInputs(for: sessionID).first(where: { $0.id == itemID })
        }

        var body: some View {
            Group {
                if let item {
                    detailBody(item)
                } else {
                    ContentUnavailableView("Message not found", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .navigationTitle("Queued message")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                draftText = item?.text ?? ""
            }
        }

        private func detailBody(_ item: CodexQueuedUserInputItem) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Text")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        TextEditor(text: $draftText)
                            .frame(minHeight: 110)
                            .padding(10)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08))
                            )

                        Button("Save changes") {
                            saveDraft(item)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if !item.attachments.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Attachments")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(item.attachments) { attachment in
                                HStack(spacing: 8) {
                                    Text(attachment.displayName)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Button(role: .destructive) {
                                        removeAttachment(item: item, attachmentID: attachment.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption.weight(.semibold))
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }

                    if item.status == .failed, let error = item.error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack(spacing: 10) {
                        if canInterrupt {
                            Button("Steer") {
                                store.steerQueuedCodexInput(sessionID: sessionID, queueItemID: item.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(item.status == .sending)
                        }

                        Button("Delete", role: .destructive) {
                            store.removeQueuedCodexInput(sessionID: sessionID, queueItemID: item.id)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(16)
            }
        }

        private func saveDraft(_ item: CodexQueuedUserInputItem) {
            var updated = item
            updated.text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            if updated.status == .failed {
                updated.status = .queued
                updated.error = nil
            }
            store.updateCodexQueuedInput(sessionID: sessionID, item: updated)
        }

        private func removeAttachment(item: CodexQueuedUserInputItem, attachmentID: UUID) {
            var updated = item
            updated.attachments.removeAll { $0.id == attachmentID }
            if updated.status == .failed {
                updated.status = .queued
                updated.error = nil
            }
            store.updateCodexQueuedInput(sessionID: sessionID, item: updated)
        }
    }
}
#endif
