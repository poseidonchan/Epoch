#if os(iOS)
import EpochCore
import SwiftUI

struct AddLinkSheet: View {
    let projectID: UUID
    let onDismiss: () -> Void

    @EnvironmentObject private var store: AppStore

    @State private var urlText = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://...", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("URL")
                } footer: {
                    Text("Paste a web page, arXiv paper, or PDF link. The content will be fetched, indexed, and available as project context.")
                }

                if isSubmitting {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Adding link...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Add Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { submit() }
                        .disabled(!isValidUrl || isSubmitting)
                }
            }
        }
    }

    private var isValidUrl: Bool {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    private func submit() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSubmitting = true
        Task {
            await store.addProjectLink(projectID: projectID, url: trimmed)
            isSubmitting = false
            onDismiss()
        }
    }
}
#endif
