import Foundation

@MainActor
internal final class ProjectService {
    private unowned let store: AppStore

    init(store: AppStore) {
        self.store = store
    }
}
