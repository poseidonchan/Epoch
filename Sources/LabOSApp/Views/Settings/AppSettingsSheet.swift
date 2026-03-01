#if os(iOS)
import LabOSCore
import SwiftUI
import UIKit
import UserNotifications

struct AppSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    @State private var wsURLString = ""
    @State private var token = ""
    @State private var openAIAPIKey = ""
    @State private var openAIVoiceModel: OpenAIVoiceTranscriptionModel = .gpt4oMiniTranscribe
    @State private var openAIVoicePrompt = OpenAIVoiceSettings.defaultTranscriptionPrompt
    @State private var openAIOcrModelSelection = "gpt-5.2"
    @State private var openAIOcrModelCustom = ""
    @State private var hpcPartition = ""
    @State private var hpcAccount = ""
    @State private var hpcQos = ""
    @State private var saveToastText: String?
    @State private var showHubQRScanner = false

    private static let ocrPresetModels = ["gpt-5.2", "gpt-5.2-chat-latest", "gpt-5.2-pro"]
    private static let ocrCustomSelection = "__custom__"

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

                    Button {
                        showHubQRScanner = true
                    } label: {
                        Label("Scan Hub QR", systemImage: "qrcode.viewfinder")
                    }
                    .accessibilityIdentifier("settings.gateway.scanQr")

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

                Section("OpenAI") {
                    SecureField("OpenAI API key", text: $openAIAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.openai.key")

                    Picker("Transcription model", selection: $openAIVoiceModel) {
                        ForEach(OpenAIVoiceTranscriptionModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .accessibilityIdentifier("settings.openai.model")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transcription prompt")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextEditor(text: $openAIVoicePrompt)
                            .frame(minHeight: 110)
                            .accessibilityIdentifier("settings.openai.prompt")
                    }

                    Picker("OCR model", selection: $openAIOcrModelSelection) {
                        ForEach(Self.ocrPresetModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                        Text("Custom").tag(Self.ocrCustomSelection)
                    }
                    .accessibilityIdentifier("settings.openai.ocrModel")

                    if openAIOcrModelSelection == Self.ocrCustomSelection {
                        TextField("Custom OCR model id", text: $openAIOcrModelCustom)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("settings.openai.ocrModel.custom")
                    }

                    LabeledContent("Local key", value: store.openAIAPIKeyConfigured ? "Configured" : "Missing API key")
                        .accessibilityIdentifier("settings.openai.status")
                    LabeledContent("Hub sync", value: openAIHubStatusText)
                        .accessibilityIdentifier("settings.openai.hubStatus")
                    LabeledContent("Hub OCR model", value: openAIHubOcrModelStatusText)
                        .accessibilityIdentifier("settings.openai.hubOcrModel")

                    Button("Save") {
                        store.saveOpenAIVoiceSettings(
                            apiKey: openAIAPIKey,
                            transcriptionModel: openAIVoiceModel,
                            transcriptionPrompt: openAIVoicePrompt,
                            ocrModel: selectedOcrModel
                        )
                        openAIAPIKey = ""
                        openAIVoiceModel = store.openAIVoiceTranscriptionModel
                        openAIVoicePrompt = store.openAIVoiceTranscriptionPrompt
                        applyOcrModelSelection(store.openAIOcrModel)
                        showToast("OpenAI settings saved")
                    }
                    .accessibilityIdentifier("settings.openai.save")

                    if store.openAIAPIKeyConfigured {
                        Button("Clear API key", role: .destructive) {
                            store.clearOpenAIAPIKey()
                            openAIAPIKey = ""
                            showToast("OpenAI API key cleared")
                        }
                        .accessibilityIdentifier("settings.openai.clear")
                    }
                }

                Section("Backend") {
                    LabeledContent("Engine", value: "Codex App Server")
                        .accessibilityIdentifier("settings.backend.engine")
                    LabeledContent("Codex RPC", value: codexConnectionStatusText)

                    if let activeSession = store.activeSession {
                        LabeledContent("Active session", value: activeSession.title)
                        LabeledContent("Session backend", value: "Codex App Server")
                    } else if let activeProject = store.activeProject {
                        LabeledContent("Active project", value: activeProject.name)
                        LabeledContent("Project backend", value: "Codex App Server")
                    } else {
                        LabeledContent("Scope", value: "Used for new projects/sessions")
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
                openAIAPIKey = ""
                openAIVoiceModel = store.openAIVoiceTranscriptionModel
                openAIVoicePrompt = store.openAIVoiceTranscriptionPrompt
                applyOcrModelSelection(store.openAIOcrModel)
                hpcPartition = store.hpcPartition
                hpcAccount = store.hpcAccount
                hpcQos = store.hpcQos
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showHubQRScanner) {
            NavigationStack {
                ZStack(alignment: .top) {
                    QRCodeScannerSheet(
                        onScanned: { scannedValue in
                            showHubQRScanner = false
                            handleScannedHubQRCode(scannedValue)
                        },
                        onError: { message in
                            showHubQRScanner = false
                            showToast(message)
                        }
                    )
                    .ignoresSafeArea()

                    VStack(spacing: 8) {
                        Text("Scan Hub QR")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Point your camera at the QR shown by `labos-hub init`.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.88))
                    }
                    .padding(12)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 20)
                    .padding(.horizontal, 16)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") {
                            showHubQRScanner = false
                        }
                    }
                }
            }
        }
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

    private var codexConnectionStatusText: String {
        switch store.codexConnectionState {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case let .failed(message):
            return "Failed: \(message)"
        }
    }

    private var openAIHubStatusText: String {
        guard let status = store.openAIHubSettingsStatus else {
            return store.isGatewayConnected ? "Unknown" : "Gateway offline"
        }
        if status.configured {
            if let updatedAt = status.updatedAt {
                return "Configured • \(AppFormatters.shortDate.string(from: updatedAt))"
            }
            return "Configured"
        }
        return "Not configured"
    }

    private var selectedOcrModel: String {
        if openAIOcrModelSelection == Self.ocrCustomSelection {
            let custom = openAIOcrModelCustom.trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty ? "gpt-5.2" : custom
        }
        let selected = openAIOcrModelSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? "gpt-5.2" : selected
    }

    private var openAIHubOcrModelStatusText: String {
        guard let status = store.openAIHubSettingsStatus else {
            return store.isGatewayConnected ? "Unknown" : "Gateway offline"
        }
        let hubModel = status.ocrModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHubModel = (hubModel?.isEmpty == false) ? hubModel! : "gpt-5.2"
        if normalizedHubModel.caseInsensitiveCompare(selectedOcrModel) == .orderedSame {
            return "Synced • \(normalizedHubModel)"
        }
        return "Hub: \(normalizedHubModel) (not synced)"
    }

    private func applyOcrModelSelection(_ model: String) {
        let normalizedRaw = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedRaw.isEmpty ? "gpt-5.2" : normalizedRaw
        if Self.ocrPresetModels.contains(normalized) {
            openAIOcrModelSelection = normalized
            openAIOcrModelCustom = ""
            return
        }
        openAIOcrModelSelection = Self.ocrCustomSelection
        openAIOcrModelCustom = normalized
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

    private func handleScannedHubQRCode(_ raw: String) {
        Task { @MainActor in
            do {
                try await store.applyHubPairingQRCode(raw)
                wsURLString = store.gatewayWSURLString
                token = store.gatewayToken
                showToast(store.isGatewayConnected ? "Hub paired" : gatewayStatusText)
            } catch {
                showToast(error.localizedDescription)
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
