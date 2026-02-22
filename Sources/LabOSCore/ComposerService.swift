import Foundation

@MainActor
internal final class ComposerService {
    private unowned let store: AppStore

    init(store: AppStore) {
        self.store = store
    }
}
