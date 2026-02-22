#if os(iOS)
import LabOSCore
import SwiftUI

struct ProjectsDrawerView: View {
    @EnvironmentObject private var store: AppStore

    @State private var showingCreate = false
    @State private var renameProject: Project?
    @State private var deleteProject: Project?
    @State private var searchQuery = ""

    private var filteredProjects: [Project] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.projects }
        return store.projects.filter { projectMatchesSearch($0, query: query) }
    }

    private let userName = "LabOS User"
    private let userSubtitle = "Local profile"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("Search", text: $searchQuery)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("drawer.project.search")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color(.secondarySystemFill)))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.08))
                    )

                    Button {
                        showingCreate = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(Color(.secondarySystemFill)))
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("drawer.project.create")
                }

                HStack(spacing: 10) {
                    labOSMark

                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                            store.backToProjects()
                            store.closeLeftPanel()
                        }
                    } label: {
                        Text("LabOS")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("drawer.home.button")

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
            }
            .padding(16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredProjects) { project in
                        projectRow(project)
                    }

                    if filteredProjects.isEmpty {
                        Text(searchQuery.isEmpty ? "No projects yet." : "No matching projects.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 14)
            }

            Spacer(minLength: 0)

            userFooter
        }
        .background(
            Color(.systemBackground)
        )
        .sheet(isPresented: $showingCreate) {
            NamePromptSheet(
                title: "Create Project",
                placeholder: "Project name",
                confirmLabel: "Create",
                onConfirm: { name in
                    Task {
                        _ = await store.createProject(name: name)
                        showingCreate = false
                        store.closeLeftPanel()
                    }
                },
                onCancel: {
                    showingCreate = false
                }
            )
        }
        .sheet(item: $renameProject) { project in
            NamePromptSheet(
                title: "Rename Project",
                placeholder: "Project name",
                confirmLabel: "Save",
                initialValue: project.name,
                onConfirm: { newName in
                    store.renameProject(projectID: project.id, newName: newName)
                    renameProject = nil
                },
                onCancel: {
                    renameProject = nil
                }
            )
        }
        .sheet(item: $deleteProject) { project in
            ProjectDeleteSheet(project: project) {
                store.deleteProject(projectID: project.id)
                deleteProject = nil
            } onCancel: {
                deleteProject = nil
            }
        }
    }

    private var labOSMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemFill))
            Image(systemName: "flask.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
        }
        .frame(width: 30, height: 30)
    }

    private func projectRow(_ project: Project) -> some View {
        let isActive = store.activeProjectID == project.id

        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                store.openProject(projectID: project.id)
                store.closeLeftPanel()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("Updated \(AppFormatters.relativeDate.localizedString(for: project.updatedAt, relativeTo: .now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? Color(.tertiarySystemFill) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier("drawer.project.row.\(project.id.uuidString.lowercased())")
        .contextMenu {
            Button("Rename") {
                renameProject = project
            }

            Button("Delete Project", role: .destructive) {
                deleteProject = project
            }
        }
    }

    private var userFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)

            HStack(spacing: 12) {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text(initials(from: userName))
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(userName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(userSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.thinMaterial)
        }
    }

    private func initials(from name: String) -> String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        if words.isEmpty { return "LU" }
        return words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    private func projectMatchesSearch(_ project: Project, query: String) -> Bool {
        let normalizedQuery = normalized(query)
        let normalizedName = normalized(project.name)
        let tokens = normalizedTokens(from: normalizedName)

        let isSingleASCIIAlphaNumeric = normalizedQuery.count == 1 && normalizedQuery.unicodeScalars.allSatisfy {
            $0.isASCII && CharacterSet.alphanumerics.contains($0)
        }

        if isSingleASCIIAlphaNumeric {
            if normalizedName.hasPrefix(normalizedQuery) {
                return true
            }
            let initials = tokens.compactMap(\.first).map { String($0) }.joined()
            return initials.contains(normalizedQuery) || tokens.contains(where: { $0.hasPrefix(normalizedQuery) })
        }

        if normalizedName.contains(normalizedQuery) {
            return true
        }

        let initials = tokens.compactMap(\.first).map { String($0) }.joined()
        return initials.contains(normalizedQuery) || tokens.contains(where: { $0.hasPrefix(normalizedQuery) })
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedTokens(from normalizedName: String) -> [String] {
        normalizedName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}

private struct ProjectDeleteSheet: View {
    let project: Project
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var typedName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Delete project '\(project.name)'?")
                        .font(.headline)
                    Text("This permanently deletes all sessions and all artifacts/files in the project workspace.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Type project name to confirm") {
                    TextField(project.name, text: $typedName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("drawer.project.delete.confirmationField")
                }
            }
            .navigationTitle("Delete Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .accessibilityIdentifier("drawer.project.delete.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive, action: onDelete)
                        .disabled(typedName != project.name)
                        .accessibilityIdentifier("drawer.project.delete.confirm")
                }
            }
        }
        .presentationDetents([.fraction(0.45), .large])
    }
}
#endif
