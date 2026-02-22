import Foundation

@MainActor
internal final class PlanApprovalService {
    private unowned let store: AppStore

    init(store: AppStore) {
        self.store = store
    }
}
