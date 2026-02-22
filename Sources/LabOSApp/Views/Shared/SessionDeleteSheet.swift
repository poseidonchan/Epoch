#if os(iOS)
import LabOSCore
import SwiftUI

struct SessionDeleteSheet: View {
    let session: Session
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Delete session '\(session.title)'?")
                        .font(.headline)
                    Text("This removes chat history but keeps all artifacts and project files.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Delete Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive, action: onDelete)
                }
            }
        }
        .presentationDetents([.fraction(0.33), .medium])
    }
}
#endif
