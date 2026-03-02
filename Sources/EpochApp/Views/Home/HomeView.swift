#if os(iOS)
import EpochCore
import SwiftUI
import UIKit
import UserNotifications

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var runningTaskIndex = 0

    private let runningTasksTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                pendingApprovalsCard
                runningTasksCard
                resourceCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Button {
                    store.openLeftPanel()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.headline)
                        .padding(8)
                }
                .accessibilityIdentifier("home.sidebar.button")

                Spacer()

                Text("Home")
                    .font(.headline)

                Spacer()

                Button {
                    store.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.headline)
                        .padding(8)
                }
                .accessibilityIdentifier("home.settings.button")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(greeting)
                .font(.title2.weight(.semibold))
        }
    }

    private var runningTasksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Running Tasks")
                    .font(.headline)
                Spacer()
                Text("\(store.homeTasks.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.blue.opacity(0.16)))
            }

            if store.homeTasks.isEmpty {
                Text("No tasks running.")
                    .foregroundStyle(.secondary)
            } else {
                TabView(selection: $runningTaskIndex) {
                    ForEach(Array(store.homeTasks.enumerated()), id: \.element.id) { index, row in
                        runningTaskSlide(row)
                            .tag(index)
                    }
                }
                .frame(height: 108)
                .tabViewStyle(.page(indexDisplayMode: store.homeTasks.count > 1 ? .automatic : .never))
                .onReceive(runningTasksTimer) { _ in
                    guard store.homeTasks.count > 1 else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        runningTaskIndex = (runningTaskIndex + 1) % store.homeTasks.count
                    }
                }
                .onChange(of: store.homeTasks.count) { _, newCount in
                    guard newCount > 0 else {
                        runningTaskIndex = 0
                        return
                    }
                    runningTaskIndex = min(runningTaskIndex, newCount - 1)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private var pendingApprovalsCard: some View {
        let rows = store.homePendingApprovals
        let preview = Array(rows.prefix(4))

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pending Approvals")
                    .font(.headline)
                Spacer()
                Text("\(rows.count)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
            }

            if rows.isEmpty {
                Text("No pending input needed.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(preview) { row in
                        pendingApprovalRow(row)
                    }
                    if rows.count > preview.count {
                        Text("+\(rows.count - preview.count) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func pendingApprovalRow(_ row: HomePendingApprovalRow) -> some View {
        Button {
            store.openSession(projectID: row.projectID, sessionID: row.sessionID)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(row.sessionTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(row.pendingCount) item\(row.pendingCount == 1 ? "" : "s") · \(pendingKindLabel(row.pendingKind))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label("Open", systemImage: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.tertiarySystemBackground)))
        }
        .buttonStyle(.plain)
    }

    private func runningTaskSlide(_ row: HomeTaskRow) -> some View {
        Button {
            store.openRun(projectID: row.projectID, runID: row.runID)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(row.projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(row.status.rawValue.capitalized)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(row.status == .running ? Color.blue.opacity(0.18) : Color.orange.opacity(0.18)))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Step")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                HStack {
                    Text(row.progressText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        store.openRun(projectID: row.projectID, runID: row.runID)
                    } label: {
                        Label("Open", systemImage: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemBackground)))
    }

    private var resourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compute Resource Monitor")
                .font(.headline)

            HStack {
                metricBlock(value: store.resourceStatus.computeConnected ? "Connected" : "Disconnected", label: "Compute")
                Spacer()
                metricBlock(
                    value: slurmJobsSummary(),
                    label: store.resourceStatus.hpc == nil ? "Queue depth" : "Slurm Jobs"
                )
            }

            HStack {
                metricBlock(value: "\(Int(store.resourceStatus.storageUsedPercent))%", label: "Storage")
                Spacer()
                metricBlock(
                    value: slurmUsageSummary(),
                    label: store.resourceStatus.hpc == nil ? "Usage" : "Allocation"
                )
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func metricBlock(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        if hour < 12 { return "Good morning" }
        if hour < 18 { return "Good afternoon" }
        return "Welcome back"
    }

    private func pendingKindLabel(_ kind: String?) -> String {
        switch kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approval":
            return "Approval"
        case "plan":
            return "Plan"
        case "prompt":
            return "Prompt"
        default:
            return "Input"
        }
    }

    private func slurmJobsSummary() -> String {
        if let hpc = store.resourceStatus.hpc {
            return "R \(hpc.runningJobs) / PD \(hpc.pendingJobs)"
        }
        return "\(store.resourceStatus.queueDepth)"
    }

    private func slurmUsageSummary() -> String {
        guard let hpc = store.resourceStatus.hpc else {
            return "CPU \(Int(store.resourceStatus.cpuPercent))% / RAM \(Int(store.resourceStatus.ramPercent))%"
        }

        let cpu = usagePair(used: hpc.inUse?.cpu, limit: hpc.limit?.cpu)
        let gpu = usagePair(used: hpc.inUse?.gpus, limit: hpc.limit?.gpus)
        return "CPU \(cpu) · GPU \(gpu)"
    }

    private func usagePair(used: Int?, limit: Int?) -> String {
        let usedText = used.map(String.init) ?? "—"
        let limitText = limit.map(String.init) ?? "—"
        return "\(usedText)/\(limitText)"
    }
}

#endif
