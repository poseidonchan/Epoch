import Combine
import Foundation

@MainActor
internal final class ChatSessionService {
    private unowned let store: AppStore

    init(store: AppStore) {
        self.store = store
    }
}
