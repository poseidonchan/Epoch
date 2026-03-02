#if os(iOS)
import EpochCore
import SwiftUI

struct QueueItemDetailView: View {
    let sessionID: UUID
    let itemID: UUID

    @EnvironmentObject private var store: AppStore

    @State private var draftText: String = ""

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
                    Button {
                        saveDraft(item)
                    } label: {
                        Label("Save", systemImage: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.14))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.18))
                    )

                    Button(role: .destructive) {
                        store.removeQueuedCodexInput(sessionID: sessionID, queueItemID: item.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.12))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.red.opacity(0.22))
                    )
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
#endif
