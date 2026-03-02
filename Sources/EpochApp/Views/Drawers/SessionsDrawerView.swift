#if os(iOS)
import EpochCore
import SwiftUI

struct SessionsDrawerView: View {
    let projectID: UUID

    @EnvironmentObject private var store: AppStore

    @State private var renameSession: Session?
    @State private var deleteSession: Session?

    private var isSessionContext: Bool {
        store.activeSessionID != nil
    }

    private var backLabel: String {
        isSessionContext ? "Back to Project" : "Back to Projects"
    }

    private var projectName: String {
        store.projects.first(where: { $0.id == projectID })?.name ?? "Project"
    }

    private var activeSessions: [Session] {
        store.sessions(for: projectID).filter { $0.lifecycle == .active }
    }

    private var archivedSessions: [Session] {
        store.sessions(for: projectID).filter { $0.lifecycle == .archived }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        if isSessionContext {
                            store.backToProject()
                        } else {
                            store.backToProjects()
                        }
                        store.closeLeftPanel()
                    }
                } label: {
                    Label(backLabel, systemImage: "chevron.left")
                        .font(.subheadline)
                }

                Text(projectName)
                    .font(.headline)

                Button {
                    Task {
                        _ = await store.createSession(projectID: projectID)
                        store.closeLeftPanel()
                    }
                } label: {
                    Label("New Session", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    section(title: "Sessions", sessions: activeSessions)

                    if !archivedSessions.isEmpty {
                        section(title: "Archived", sessions: archivedSessions)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .sheet(item: $renameSession) { session in
            NamePromptSheet(
                title: "Rename Session",
                placeholder: "Session title",
                confirmLabel: "Save",
                initialValue: session.title,
                onConfirm: { name in
                    store.renameSession(projectID: projectID, sessionID: session.id, newTitle: name)
                    renameSession = nil
                },
                onCancel: {
                    renameSession = nil
                }
            )
        }
        .sheet(item: $deleteSession) { session in
            SessionDeleteSheet(session: session) {
                store.deleteSession(projectID: projectID, sessionID: session.id)
                deleteSession = nil
            } onCancel: {
                deleteSession = nil
            }
        }
    }

    private func section(title: String, sessions: [Session]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            ForEach(sessions) { session in
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        store.openSession(projectID: projectID, sessionID: session.id)
                        store.closeLeftPanel()
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("Updated \(AppFormatters.relativeDate.localizedString(for: session.updatedAt, relativeTo: .now))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.activeSessionID == session.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Rename") {
                        renameSession = session
                    }

                    if session.lifecycle == .active {
                        Button("Archive") {
                            store.archiveSession(projectID: projectID, sessionID: session.id)
                        }
                    } else {
                        Button("Unarchive") {
                            store.unarchiveSession(projectID: projectID, sessionID: session.id)
                        }
                    }

                    Button("Delete Session", role: .destructive) {
                        deleteSession = session
                    }
                }
            }
        }
    }
}
#endif
