#if os(iOS)
import EpochCore
import SwiftUI

struct CodexTrajectoryGroupView: View {
    let group: CodexTrajectoryGroup
    let isExpanded: Bool
    let isLeafExpanded: (String) -> Bool
    let onToggleGroup: () -> Void
    let onToggleLeaf: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggleGroup) {
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(title) (\(group.leaves.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("codex.trajectory.group.toggle.\(group.id.lowercased())")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.leaves) { leaf in
                        CodexTrajectoryLeafView(
                            leaf: leaf,
                            isExpanded: isLeafExpanded(leaf.id),
                            onToggle: {
                                onToggleLeaf(leaf.id)
                            }
                        )
                    }
                }
                .padding(.leading, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("codex.trajectory.group.\(group.id.lowercased())")
    }

    private var title: String {
        switch group.family {
        case .search:
            return "Search"
        case .list:
            return "List"
        case .read:
            return "Read"
        case .write:
            return "Write"
        case .exec:
            return "Exec"
        case .other:
            return "Other"
        }
    }

    private var iconName: String {
        switch group.family {
        case .search:
            return "magnifyingglass"
        case .list:
            return "list.bullet"
        case .read:
            return "doc.text"
        case .write:
            return "square.and.pencil"
        case .exec:
            return "terminal"
        case .other:
            return "circle.grid.2x2"
        }
    }
}
#endif
