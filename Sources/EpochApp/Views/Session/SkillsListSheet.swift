#if os(iOS)
import EpochCore
import SwiftUI

struct SkillsListSheet: View {
    let sessionID: UUID

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""

    private var state: CodexSkillsListState {
        store.codexSkillsState(for: sessionID)
    }

    private var filteredEntries: [CodexSkillsListEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return state.entries }

        return state.entries.map { entry in
            let filteredSkills = entry.skills.filter { skill in
                let name = skill.name.lowercased()
                let path = skill.path.lowercased()
                let scope = (skill.scope ?? "").lowercased()
                let description = (skill.shortDescription ?? skill.description ?? "").lowercased()
                return name.contains(query)
                    || path.contains(query)
                    || scope.contains(query)
                    || description.contains(query)
            }
            return CodexSkillsListEntry(cwd: entry.cwd, errors: entry.errors, skills: filteredSkills)
        }.filter { !$0.skills.isEmpty || !$0.errors.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if state.isLoading && state.entries.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading skills…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = state.error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, state.entries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Failed to load skills")
                            .font(.headline)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Retry") {
                            store.refreshCodexSkills(sessionID: sessionID, forceReload: true)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if !state.entries.isEmpty {
                            ForEach(filteredEntries) { entry in
                                Section(entry.cwd.isEmpty ? "Workspace" : entry.cwd) {
                                    if !entry.errors.isEmpty {
                                        ForEach(Array(entry.errors.enumerated()), id: \.offset) { _, error in
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(error.path)
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.secondary)
                                                Text(error.message)
                                                    .font(.caption)
                                                    .foregroundStyle(.red)
                                            }
                                            .padding(.vertical, 4)
                                        }
                                    }

                                    if entry.skills.isEmpty {
                                        Text("No skills matched")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(entry.skills.sorted(by: skillSort)) { skill in
                                            skillRow(skill)
                                        }
                                    }
                                }
                            }
                        } else {
                            Text("No skills available")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
                    .overlay(alignment: .bottom) {
                        if state.isLoading {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Refreshing…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                            .padding(.bottom, 16)
                            .transition(.opacity)
                        }
                    }
                }
            }
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.refreshCodexSkills(sessionID: sessionID, forceReload: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh skills")
                }
            }
            .onAppear {
                if state.updatedAt == nil && !state.isLoading {
                    store.refreshCodexSkills(sessionID: sessionID)
                }
            }
        }
    }

    private func skillSort(_ lhs: CodexSkillMetadata, _ rhs: CodexSkillMetadata) -> Bool {
        let lhsScope = lhs.scope ?? ""
        let rhsScope = rhs.scope ?? ""
        if lhsScope != rhsScope { return lhsScope < rhsScope }
        return lhs.name < rhs.name
    }

    @ViewBuilder
    private func skillRow(_ skill: CodexSkillMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(skill.interface?.displayName ?? skill.name)
                    .font(.subheadline.weight(.semibold))

                if let scope = skill.scope, !scope.isEmpty {
                    Text(scope)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(.tertiarySystemFill))
                        )
                }

                Spacer(minLength: 0)

                if let enabled = skill.enabled {
                    Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(enabled ? Color.green : Color.secondary)
                        .accessibilityLabel(enabled ? "Enabled" : "Disabled")
                }
            }

            if let shortDescription = skill.shortDescription, !shortDescription.isEmpty {
                Text(shortDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let description = skill.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(skill.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

#endif
