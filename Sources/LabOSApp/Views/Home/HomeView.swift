#if os(iOS)
import LabOSCore
import SwiftUI
import UIKit
import UserNotifications

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingSettings = false
    @State private var runningTaskIndex = 0

    private let runningTasksTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
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
                    showingSettings = true
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
        .sheet(isPresented: $showingSettings) {
            HomeSettingsSheet()
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
                metricBlock(value: "\(store.resourceStatus.queueDepth)", label: "Queue depth")
            }

            HStack {
                metricBlock(value: "\(Int(store.resourceStatus.storageUsedPercent))%", label: "Storage")
                Spacer()
                metricBlock(value: "CPU \(Int(store.resourceStatus.cpuPercent))% / RAM \(Int(store.resourceStatus.ramPercent))%", label: "Usage")
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
}

private struct HomeSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    @State private var wsURLString = ""
    @State private var token = ""
    @State private var hpcPartition = ""
    @State private var hpcAccount = ""
    @State private var hpcQos = ""
    @State private var saveToastText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: "Local User")
                    LabeledContent("Plan", value: "LabOS v0.1")
                }

                Section("Gateway") {
                    TextField("ws://host:8787/ws", text: $wsURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.gateway.url")

                    SecureField("Shared token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.gateway.token")

                    LabeledContent("Status", value: gatewayStatusText)
                        .accessibilityIdentifier("settings.gateway.status")

                    Button("Save") {
                        store.saveGatewaySettings(wsURLString: wsURLString, token: token)
                        wsURLString = store.gatewayWSURLString
                        token = store.gatewayToken
                        showToast("Gateway saved")
                    }
                    .accessibilityIdentifier("settings.gateway.save")

                    if store.isGatewayConnected {
                        Button("Disconnect", role: .destructive) {
                            store.disconnectGateway()
                        }
                        .accessibilityIdentifier("settings.gateway.disconnect")
                    } else {
                        Button("Connect") {
                            store.saveGatewaySettings(wsURLString: wsURLString, token: token)
                            wsURLString = store.gatewayWSURLString
                            token = store.gatewayToken
                            Task { await store.connectGateway() }
                        }
                        .disabled(wsURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || token.isEmpty)
                        .accessibilityIdentifier("settings.gateway.connect")
                    }
                }

                Section("HPC") {
                    TextField("Partition", text: $hpcPartition)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.hpc.partition")

                    TextField("Account", text: $hpcAccount)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.hpc.account")

                    TextField("QoS", text: $hpcQos)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.hpc.qos")

                    Button("Save") {
                        store.saveHpcSettings(partition: hpcPartition, account: hpcAccount, qos: hpcQos)
                        hpcPartition = store.hpcPartition
                        hpcAccount = store.hpcAccount
                        hpcQos = store.hpcQos
                        store.pushHpcPreferencesToGateway()
                        showToast(store.isGatewayConnected ? "HPC saved and pushed" : "HPC saved")
                    }
                    .accessibilityIdentifier("settings.hpc.save")

                    if let hpc = store.resourceStatus.hpc {
                        LabeledContent("Scope", value: hpcScopeText(hpc))
                        LabeledContent("Jobs", value: "R \(hpc.runningJobs) / PD \(hpc.pendingJobs)")
                        LabeledContent("Quota remaining", value: formatTres(hpc.available))
                    } else {
                        LabeledContent("Status", value: store.isGatewayConnected ? "Waiting for bridge…" : "Connect gateway to view")
                    }
                }

                Section("Preferences") {
                    NavigationLink {
                        NotificationSettingsView()
                            .environmentObject(store)
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }

                    NavigationLink {
                        DataStorageSettingsView()
                            .environmentObject(store)
                    } label: {
                        Label("Data & Storage", systemImage: "externaldrive")
                    }

                    NavigationLink {
                        AboutLabOSView()
                    } label: {
                        Label("About LabOS", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("settings.done")
                }
            }
            .onAppear {
                wsURLString = store.gatewayWSURLString
                token = store.gatewayToken
                hpcPartition = store.hpcPartition
                hpcAccount = store.hpcAccount
                hpcQos = store.hpcQos
            }
        }
        .presentationDetents([.medium, .large])
        .overlay(alignment: .bottom) {
            if let saveToastText {
                Text(saveToastText)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .foregroundStyle(.white)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
    }

    private var gatewayStatusText: String {
        switch store.gatewayConnectionState {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting…"
        case let .connected(connectionID):
            return "Connected (\(connectionID.uuidString.prefix(8)))"
        case let .failed(message):
            return "Failed: \(message)"
        }
    }

    private func hpcScopeText(_ hpc: HPCStatus) -> String {
        let p = hpc.partition?.isEmpty == false ? hpc.partition! : "—"
        let a = hpc.account?.isEmpty == false ? hpc.account! : "—"
        let q = hpc.qos?.isEmpty == false ? hpc.qos! : "—"
        return "p=\(p) a=\(a) q=\(q)"
    }

    private func formatTres(_ tres: HPCStatus.Tres?) -> String {
        guard let tres else { return "—" }
        let cpu = tres.cpu.map(String.init) ?? "—"
        let gpu = tres.gpus.map(String.init) ?? "—"
        let mem = tres.memMB.map { "\($0) MB" } ?? "—"
        return "CPU \(cpu) / GPU \(gpu) / Mem \(mem)"
    }

    private func showToast(_ text: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            saveToastText = text
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            guard saveToastText == text else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                saveToastText = nil
            }
        }
    }
}

private struct NotificationSettingsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var isUpdatingPreference = false
    @State private var hintText: String?

    var body: some View {
        Form {
            Section("Run Completion") {
                Toggle("Notify when a task completes", isOn: notificationToggleBinding)
                    .disabled(isUpdatingPreference)

                LabeledContent("System permission", value: authorizationStatusText)

                if let hintText {
                    Text(hintText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if authorizationStatus == .denied {
                    Button("Open iOS Settings") {
                        openSystemSettings()
                    }
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshAuthorizationStatus()
        }
    }

    private var notificationToggleBinding: Binding<Bool> {
        Binding(
            get: { store.runCompletionNotificationsEnabled },
            set: { enabled in
                Task {
                    await updateNotificationPreference(enabled: enabled)
                }
            }
        )
    }

    private var authorizationStatusText: String {
        switch authorizationStatus {
        case .authorized:
            return "Authorized"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not determined"
        @unknown default:
            return "Unknown"
        }
    }

    private func refreshAuthorizationStatus() async {
        let status = await LocalNotifications.authorizationStatus()
        await MainActor.run {
            authorizationStatus = status
        }
    }

    private func updateNotificationPreference(enabled: Bool) async {
        await MainActor.run {
            isUpdatingPreference = true
            hintText = nil
        }
        defer {
            Task { @MainActor in
                isUpdatingPreference = false
            }
        }

        if enabled {
            let status = await LocalNotifications.authorizationStatus()
            switch status {
            case .authorized, .provisional, .ephemeral:
                await MainActor.run {
                    store.setRunCompletionNotificationsEnabled(true)
                }
            case .notDetermined:
                let granted = await LocalNotifications.requestAuthorization()
                await MainActor.run {
                    store.setRunCompletionNotificationsEnabled(granted)
                    if !granted {
                        hintText = "Permission is required to deliver completion alerts."
                    }
                }
            case .denied:
                await MainActor.run {
                    store.setRunCompletionNotificationsEnabled(false)
                    hintText = "Enable notifications in iOS Settings to receive completion alerts."
                }
            @unknown default:
                await MainActor.run {
                    store.setRunCompletionNotificationsEnabled(false)
                }
            }
        } else {
            await MainActor.run {
                store.setRunCompletionNotificationsEnabled(false)
            }
        }

        await refreshAuthorizationStatus()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct DataStorageSettingsView: View {
    @EnvironmentObject private var store: AppStore

    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter
    }()

    var body: some View {
        Form {
            Section("HPC Storage") {
                if let available = store.hpcStorageAvailableBytes {
                    LabeledContent("Remaining", value: formatBytes(available))
                } else {
                    LabeledContent("Remaining (estimate)", value: "\(Int(store.hpcStorageRemainingPercent.rounded()))%")
                }

                if let used = store.hpcStorageUsedBytes {
                    LabeledContent("Used", value: formatBytes(used))
                }

                if let total = store.hpcStorageTotalBytes {
                    LabeledContent("Capacity", value: formatBytes(total))
                }

                if let total = store.hpcStorageTotalBytes,
                   let used = store.hpcStorageUsedBytes,
                   total > 0
                {
                    ProgressView(value: min(max(Double(used), 0), Double(total)), total: Double(total))
                }

                LabeledContent("Usage", value: "\(Int(store.resourceStatus.storageUsedPercent.rounded()))% used")

                if !store.isGatewayConnected {
                    Text("Connect the gateway to fetch live HPC storage data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Artifact Breakdown") {
                if store.artifactStorageBreakdown.isEmpty {
                    Text("No artifacts available yet.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Total artifact storage", value: formatBytes(Int64(store.totalArtifactStorageBytes)))

                    ForEach(store.artifactStorageBreakdown) { bucket in
                        HStack {
                            Text(label(for: bucket.kind))
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(formatBytes(Int64(bucket.bytes)))
                                Text("\(bucket.itemCount) item\(bucket.itemCount == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Data & Storage")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, bytes))
    }

    private func label(for kind: ArtifactKind) -> String {
        switch kind {
        case .notebook:
            return "Notebook"
        case .python:
            return "Python"
        case .image:
            return "Image"
        case .text:
            return "Text"
        case .json:
            return "JSON"
        case .log:
            return "Log"
        case .unknown:
            return "Other"
        }
    }
}

private struct AboutLabOSView: View {
    var body: some View {
        Form {
            Section("App") {
                LabeledContent("Version", value: versionString)
                LabeledContent("Build", value: buildString)
            }

            Section("Environment") {
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
            }
        }
        .navigationTitle("About LabOS")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private var buildString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}
#endif
