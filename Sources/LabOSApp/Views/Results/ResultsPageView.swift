#if os(iOS)
import LabOSCore
import SwiftUI

struct ResultsPageView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let projectID = store.activeProjectID {
                    ArtifactsBrowserView(projectID: projectID)
                } else {
                    ContentUnavailableView(
                        "No Project Context",
                        systemImage: "folder",
                        description: Text("Open a project to browse files.")
                    )
                }
            }
            .navigationTitle("Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") {
                        store.closeResults()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear {
            store.closeResults()
        }
    }
}
#endif
