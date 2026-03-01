#if os(iOS)
import LabOSCore
import Foundation

enum SteerQueuePresentation {
    static func displayItems(from queue: [CodexQueuedUserInputItem]) -> [CodexQueuedUserInputItem] {
        Array(queue.reversed())
    }

    static func displayIDs(from queue: [CodexQueuedUserInputItem]) -> [UUID] {
        displayItems(from: queue).map(\.id)
    }

    static func priorityDisplayItem(in displayItems: [CodexQueuedUserInputItem]) -> CodexQueuedUserInputItem? {
        displayItems.last
    }

    static func actualOrderIDs(fromDisplayOrder displayIDs: [UUID], queue: [CodexQueuedUserInputItem]) -> [UUID] {
        let actualIDs = queue.map(\.id)
        let expected = Set(actualIDs)
        let received = Set(displayIDs)
        guard actualIDs.count == displayIDs.count,
              received.count == displayIDs.count,
              expected == received else {
            return actualIDs
        }
        return Array(displayIDs.reversed())
    }
}
#endif
