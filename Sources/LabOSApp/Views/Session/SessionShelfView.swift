#if os(iOS)
import LabOSCore
import SwiftUI

enum SessionShelfRenderMode {
    case cards
    case dock
}

struct SessionShelfView: View {
    let projectID: UUID
    let sessionID: UUID
    let renderMode: SessionShelfRenderMode

    @EnvironmentObject private var store: AppStore

    @State private var showQueueManager = false
    @State private var showDiffReview = false
    @State private var showRunningTerminals = false
    @State private var isTerminalsExpanded = false
    @State private var terminalEligibilityNow = Date()
    @State private var isRunProgressExpanded = false
    @State private var isPlanCardExpanded = false

    private let terminalEligibilityTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(projectID: UUID, sessionID: UUID, renderMode: SessionShelfRenderMode = .cards) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.renderMode = renderMode
    }

    private var activeRun: RunRecord? {
        store.runs(for: projectID).first { run in
            run.sessionID == sessionID && (run.status == .queued || run.status == .running)
        }
    }

    private var approvals: [CodexPendingApproval] {
        store.codexPendingApprovals(for: sessionID)
    }

    private var queuedInputs: [CodexQueuedUserInputItem] {
        store.codexQueuedInputs(for: sessionID)
    }

    private var turnDiff: CodexTurnDiffState? {
        store.codexTurnDiff(for: sessionID)
    }

    private var diffSummary: DiffSummary? {
        guard let turnDiff else { return nil }
        return Self.summarizeDiff(turnDiff.diff)
    }

    private var qualifyingRunningCommands: [CodexCommandExecutionItem] {
        store.codexRunningCommandsEligibleForShelf(
            sessionID: sessionID,
            now: terminalEligibilityNow,
            minimumDurationMs: 10_000
        )
    }

    private var runProgressAnimation: Animation {
        .interactiveSpring(response: 0.34, dampingFraction: 0.86, blendDuration: 0.12)
    }

    private var runProgressContentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.98, anchor: .top))
                .combined(with: .offset(y: -6)),
            removal: .opacity
                .combined(with: .scale(scale: 0.98, anchor: .top))
        )
    }

    private var shelfRows: [AnyView] {
        var rows: [AnyView] = []

        if let diffSummary, let turnDiff {
            rows.append(
                AnyView(
                    diffCard(summary: diffSummary, diff: turnDiff.diff)
                        .accessibilityIdentifier("session.shelf.diff")
                )
            )
        }

        if !queuedInputs.isEmpty {
            rows.append(
                AnyView(
                    queueCard(items: queuedInputs)
                        .accessibilityIdentifier("session.shelf.queue")
                )
            )
        }

        if !qualifyingRunningCommands.isEmpty {
            rows.append(
                AnyView(
                    terminalsCard(commands: qualifyingRunningCommands)
                        .accessibilityIdentifier("session.shelf.terminals")
                )
            )
        }

        if let run = activeRun {
            rows.append(AnyView(runProgressCard(run)))
        } else if let plan = store.livePlanBySession[sessionID] {
            rows.append(AnyView(agentPlanCard(plan)))
        }

        if !approvals.isEmpty {
            rows.append(AnyView(approvalsCard(approvals)))
        }

        return rows
    }

    var body: some View {
        Group {
            if renderMode == .dock {
                VStack(alignment: .leading, spacing: CodexDockTokens.sectionSpacing) {
                    ForEach(Array(shelfRows.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            dockDivider
                        }
                        row
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(shelfRows.enumerated()), id: \.offset) { _, row in
                        row
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .sheet(isPresented: $showQueueManager) {
            QueueManagerSheet(sessionID: sessionID)
                .environmentObject(store)
        }
        .sheet(isPresented: $showDiffReview) {
            DiffReviewSheet(diff: turnDiff?.diff ?? "")
        }
        .sheet(isPresented: $showRunningTerminals) {
            RunningTerminalsSheet(sessionID: sessionID)
                .environmentObject(store)
        }
        .onReceive(terminalEligibilityTimer) { value in
            terminalEligibilityNow = value
        }
        .onChange(of: qualifyingRunningCommands.map(\.id)) { _, commandIDs in
            if commandIDs.isEmpty {
                isTerminalsExpanded = false
            }
        }
    }

    // MARK: - Cards

    private var dockDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(CodexDockTokens.dividerOpacity))
            .frame(height: CodexDockTokens.dividerThickness)
            .padding(.horizontal, CodexDockTokens.dividerHorizontalInset)
    }

    @ViewBuilder
    private func cardContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        switch renderMode {
        case .cards:
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.systemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
        case .dock:
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func diffCard(summary: DiffSummary, diff: String) -> some View {
        cardContainer {
            HStack(alignment: .center, spacing: 10) {
                Text("\(summary.fileCount) files changed +\(summary.additions) -\(summary.deletions)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button("Review changes") {
                    showDiffReview = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("session.shelf.reviewDiff")
            }
        }
    }

    private func queueCard(items: [CodexQueuedUserInputItem]) -> some View {
        let previews = Array(items.prefix(2))
        let canInterrupt = store.canInterruptCodexTurn(sessionID: sessionID)

        return cardContainer {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("\(items.count) queued")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button("Manage") { showQueueManager = true }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("session.shelf.manageQueue")
                }

                ForEach(previews) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(queuePreviewTitle(item))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        if !item.attachments.isEmpty {
                            Text(queueAttachmentSummary(item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if item.status == .failed,
                           let error = item.error,
                           !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }

                        HStack(spacing: 10) {
                            Button("Steer") {
                                store.steerQueuedCodexInput(sessionID: sessionID, queueItemID: item.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canInterrupt || item.status == .sending)

                            Button {
                                store.removeQueuedCodexInput(sessionID: sessionID, queueItemID: item.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06))
                    )
                }

                if items.count > previews.count {
                    Text("+ \(items.count - previews.count) more")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func terminalsCard(commands: [CodexCommandExecutionItem]) -> some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(runProgressAnimation) {
                        isTerminalsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "terminal")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Running \(commands.count) command\(commands.count == 1 ? "" : "s")")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isTerminalsExpanded ? 90 : 0))
                            .animation(runProgressAnimation, value: isTerminalsExpanded)
                    }
                }
                .buttonStyle(.plain)

                if isTerminalsExpanded {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(commands, id: \.id) { command in
                                terminalCommandSummaryRow(command)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                    .padding(.top, 2)
                    .clipped()
                    .transition(runProgressContentTransition)
                }
            }
        }
        .contextMenu {
            Button {
                showRunningTerminals = true
            } label: {
                Label("Open terminal details", systemImage: "rectangle.stack")
            }
        }
    }

    private func terminalCommandSummaryRow(_ command: CodexCommandExecutionItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(command.command)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(command.cwd)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("Status: \(commandStatusLabel(command.status))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func commandStatusLabel(_ status: String) -> String {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "in_progress", "inprogress":
            return "In progress"
        case "completed":
            return "Completed"
        case "failed":
            return "Failed"
        default:
            let fallback = status.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? "Unknown" : fallback
        }
    }

    private func approvalsCard(_ approvals: [CodexPendingApproval]) -> some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 10) {
                Text("Approvals needed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(approvals) { approval in
                    codexApprovalRow(approval)
                }
            }
        }
    }

    private func codexApprovalRow(_ approval: CodexPendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.kind == .commandExecution ? "Command approval" : "File change approval")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(.subheadline)
            }

            if let command = approval.command, !command.isEmpty {
                Text(command)
                    .font(.system(.subheadline, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.tertiarySystemFill))
                    )
            }

            HStack(spacing: 10) {
                Button("Accept Once") {
                    store.respondToCodexApproval(sessionID: sessionID, requestID: approval.requestID, decision: "accept")
                }
                .buttonStyle(.borderedProminent)

                Button("Accept Similar") {
                    store.respondToCodexApproval(sessionID: sessionID, requestID: approval.requestID, decision: "acceptForSession")
                }
                .buttonStyle(.bordered)

                Button("Reject") {
                    store.respondToCodexApproval(sessionID: sessionID, requestID: approval.requestID, decision: "decline")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }

    // MARK: - Run Progress (migrated from SessionChatView)

    private func runProgressCard(_ run: RunRecord) -> some View {
        let total = max(run.totalSteps, 1)
        let completed = completedSteps(run)
        let fraction = min(max(Double(completed) / Double(total), 0), 1)
        let currentIndex = currentStepIndex(run: run)
        let stepCount = max(run.stepTitles.count, total)
        let currentTitle = currentIndex.flatMap { index in
            run.stepTitles.indices.contains(index) ? run.stepTitles[index] : nil
        } ?? "Waiting for execution"
        let currentDetail = currentIndex.flatMap { index in
            run.stepDetails.indices.contains(index) ? run.stepDetails[index] : nil
        } ?? "Queued and waiting for available compute."
        let recentActivity = Array(run.activity.suffix(6).reversed())

        return cardContainer {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(runProgressAnimation) {
                        isRunProgressExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)

                        Text("Run · \(completed)/\(stepCount) completed")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isRunProgressExpanded ? 90 : 0))
                            .animation(runProgressAnimation, value: isRunProgressExpanded)
                    }
                }
                .buttonStyle(.plain)

                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.orange)

                if isRunProgressExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current step")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(currentTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            Text(currentDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !recentActivity.isEmpty {
                            Text("Recent activity")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(Array(recentActivity.enumerated()), id: \.offset) { _, entry in
                                Text(entry.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.top, 2)
                    .clipped()
                    .transition(runProgressContentTransition)
                }
            }
        }
        .accessibilityIdentifier("session.run.progress.card")
    }

    private func completedSteps(_ run: RunRecord) -> Int {
        switch run.status {
        case .queued:
            return 0
        case .running:
            return max(run.currentStep - 1, 0)
        case .succeeded:
            return max(run.totalSteps, 1)
        case .failed, .canceled:
            return max(run.currentStep - 1, 0)
        }
    }

    private func currentStepIndex(run: RunRecord) -> Int? {
        switch run.status {
        case .queued:
            return 0
        case .running, .failed, .canceled:
            let step = max(min(run.currentStep, max(run.totalSteps, 1)), 1)
            return step - 1
        case .succeeded:
            return nil
        }
    }

    // MARK: - Plan Progress (migrated from SessionChatView)

    private func agentPlanCard(_ payload: AgentPlanUpdatedPayload) -> some View {
        let items = payload.plan
        let total = max(items.count, 1)
        let completed = items.filter { $0.status.lowercased() == "completed" }.count
        let fraction = min(max(Double(completed) / Double(total), 0), 1)
        let currentIndex = items.firstIndex { status in
            let normalized = status.status.lowercased()
            return normalized == "in_progress" || normalized == "inprogress"
        }
        let currentTitle = currentIndex.flatMap { items.indices.contains($0) ? items[$0].step : nil } ?? "Waiting for execution"

        return cardContainer {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(runProgressAnimation) {
                        isPlanCardExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "list.bullet.clipboard")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)

                        Text("Plan · \(completed)/\(total) completed")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isPlanCardExpanded ? 90 : 0))
                            .animation(runProgressAnimation, value: isPlanCardExpanded)
                    }
                }
                .buttonStyle(.plain)

                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.blue)

                if isPlanCardExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current step")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(currentTitle)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            if let explanation = payload.explanation?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !explanation.isEmpty {
                                Text(explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !items.isEmpty {
                            Text("Steps")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                                let status = item.status.lowercased()
                                HStack(spacing: 8) {
                                    Image(systemName: planStatusIcon(status))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(planStatusColor(status))
                                        .frame(width: 14, height: 14)

                                    Text("Step \(index + 1) · \(item.step)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(.secondarySystemBackground))
                                )
                            }
                        }
                    }
                    .padding(.top, 2)
                    .clipped()
                    .transition(runProgressContentTransition)
                }
            }
        }
        .accessibilityIdentifier("session.plan.progress.card")
    }

    private func planStatusIcon(_ status: String) -> String {
        switch status {
        case "completed":
            return "checkmark.circle.fill"
        case "in_progress", "inprogress":
            return "clock.fill"
        case "pending":
            return "circle"
        default:
            return "questionmark.circle"
        }
    }

    private func planStatusColor(_ status: String) -> Color {
        switch status {
        case "completed":
            return .green
        case "in_progress", "inprogress":
            return .blue
        case "pending":
            return .secondary
        default:
            return .secondary
        }
    }

    // MARK: - Queue Helpers

    private func queuePreviewTitle(_ item: CodexQueuedUserInputItem) -> String {
        let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if !item.attachments.isEmpty { return "Attachments only" }
        return "(empty)"
    }

    private func queueAttachmentSummary(_ item: CodexQueuedUserInputItem) -> String {
        let names = item.attachments
            .map { $0.displayName.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if names.isEmpty {
            return "\(item.attachments.count) attachment(s)"
        }
        let joined = names.prefix(3).joined(separator: ", ")
        if names.count > 3 {
            return "\(joined) +\(names.count - 3)"
        }
        return joined
    }

    // MARK: - Diff Helpers

    private struct DiffSummary: Hashable {
        var fileCount: Int
        var additions: Int
        var deletions: Int
    }

    private static func summarizeDiff(_ diff: String) -> DiffSummary {
        var fileCount = 0
        var additions = 0
        var deletions = 0

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                fileCount += 1
                continue
            }
            if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                continue
            }
            if line.hasPrefix("+") {
                additions += 1
                continue
            }
            if line.hasPrefix("-") {
                deletions += 1
                continue
            }
        }

        return DiffSummary(fileCount: fileCount, additions: additions, deletions: deletions)
    }
}
#endif
