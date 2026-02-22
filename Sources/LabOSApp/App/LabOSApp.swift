#if os(iOS)
import LabOSCore
import SwiftUI

@main
struct LabOSApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootContainerView()
                .environmentObject(store)
        }
    }
}
#endif
