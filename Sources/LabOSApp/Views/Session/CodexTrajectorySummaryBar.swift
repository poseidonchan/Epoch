#if os(iOS)
import SwiftUI

struct CodexTrajectorySummaryBar: View {
    let turnID: String
    let isExpanded: Bool
    let isStreaming: Bool
    let startedAt: Date?
    let completedDurationMs: Int?
    let estimatedDurationMs: Int?
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Spacer(minLength: 0)

                summaryLabel
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("codex.trajectory.summary.\(turnID.lowercased())")
    }

    @ViewBuilder
    private var summaryLabel: some View {
        if isStreaming, let startedAt {
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
                Text("Worked for \(Self.format(durationMs: Int(elapsed * 1_000)))")
            }
        } else {
            Text(staticSummary)
        }
    }

    private var staticSummary: String {
        if let completedDurationMs, completedDurationMs > 0 {
            return "Worked for \(Self.format(durationMs: completedDurationMs))"
        }
        if let estimatedDurationMs, estimatedDurationMs > 0 {
            return "Worked for \(Self.format(durationMs: estimatedDurationMs))"
        }
        return "Worked"
    }

    private static func format(durationMs: Int) -> String {
        let roundedSeconds = max(0, Int(round(Double(durationMs) / 1_000.0)))
        // Avoid confusing "0s" labels for quick turns.
        let seconds = durationMs > 0 && roundedSeconds == 0 ? 1 : roundedSeconds
        if seconds < 60 {
            return "\(seconds)s"
        }

        let minutes = seconds / 60
        let remainderSeconds = seconds % 60
        if minutes < 60 {
            if remainderSeconds == 0 {
                return "\(minutes)m"
            }
            return "\(minutes)m \(remainderSeconds)s"
        }

        let hours = minutes / 60
        let remainderMinutes = minutes % 60
        if remainderMinutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(remainderMinutes)m"
    }
}
#endif
