#if os(iOS)
import Combine
import EpochCore
import SwiftUI
import UserNotifications

struct RootContainerView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var notificationRouter: AppNotificationRouter

    var body: some View {
        GeometryReader { proxy in
            let leftWidth = min(proxy.size.width * 0.82, 340)
            let canPresentLeftPanel = !isSessionContext
            let isLeftPanelVisible = store.isLeftPanelOpen && canPresentLeftPanel

            ZStack(alignment: .leading) {
                currentContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(x: isLeftPanelVisible ? leftWidth : 0)
                    .overlay {
                        if isLeftPanelVisible {
                            Color.black.opacity(0.22)
                                .ignoresSafeArea()
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                        store.closeLeftPanel()
                                    }
                            }
                        }
                    }
                    .highPriorityGesture(mainEdgeGesture())

                if isLeftPanelVisible {
                    leftPanel
                        .frame(width: leftWidth)
                        .transition(.move(edge: .leading))
                        .gesture(leftPanelCloseGesture)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isLeftPanelVisible)
            .background(Color(.systemBackground))
            .ignoresSafeArea(.container, edges: .bottom)
            .onChange(of: store.context) { _, newContext in
                guard case .session = newContext, store.isLeftPanelOpen else { return }
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    store.closeLeftPanel()
                }
            }
            .onChange(of: store.latestRunCompletionSignal) { _, signal in
                guard let signal, store.runCompletionNotificationsEnabled else { return }
                Task {
                    await LocalNotifications.scheduleRunCompletionIfAuthorized(signal)
                }
            }
            .onChange(of: store.latestPendingUserInputSignal) { _, signal in
                guard let signal, store.runCompletionNotificationsEnabled else { return }
                Task {
                    await LocalNotifications.schedulePendingUserInputIfAuthorized(signal)
                }
            }
            .onReceive(notificationRouter.$pendingURL.compactMap { $0 }) { url in
                store.handleDeepLink(url)
                notificationRouter.consumePendingURL(url)
            }
            .sheet(
                isPresented: Binding(
                    get: { store.isSettingsPresented },
                    set: { presented in
                        if !presented {
                            store.closeSettings()
                        }
                    }
                )
            ) {
                AppSettingsSheet()
                    .environmentObject(store)
            }
            .fullScreenCover(
                isPresented: Binding(
                    get: { store.isRightPanelOpen },
                    set: { isPresented in
                        if !isPresented {
                            store.closeResults()
                        }
                    }
                )
            ) {
                ResultsPageView()
                    .environmentObject(store)
            }
        }
    }

    private var isSessionContext: Bool {
        if case .session = store.context {
            return true
        }
        return false
    }

    @ViewBuilder
    private var currentContent: some View {
        switch store.context {
        case .home:
            HomeView()
        case let .project(projectID):
            ProjectPageView(projectID: projectID)
        case let .session(projectID, sessionID):
            SessionChatView(projectID: projectID, sessionID: sessionID)
        }
    }

    @ViewBuilder
    private var leftPanel: some View {
        switch store.context {
        case .home, .project:
            ProjectsDrawerView()
                .background(Color(.secondarySystemBackground))
        case let .session(projectID, _):
            SessionsDrawerView(projectID: projectID)
                .background(Color(.secondarySystemBackground))
        }
    }

    private func mainEdgeGesture() -> some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onEnded { value in
                let startX = value.startLocation.x
                let deltaX = value.translation.width

                if store.isLeftPanelOpen, deltaX < -70 {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        store.closeLeftPanel()
                    }
                    return
                }

                if !isSessionContext, startX < 28, deltaX > 70 {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        store.openLeftPanel()
                    }
                }
            }
    }

    private var leftPanelCloseGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                if value.translation.width < -60 {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                        store.closeLeftPanel()
                    }
                }
            }
    }
}

enum LocalNotifications {
    static func authorizationStatus() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UNAuthorizationStatus, Never>) in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    static func canDeliverNotifications(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorizationValue(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func scheduleRunCompletionIfAuthorized(_ signal: AppStore.RunCompletionSignal) async {
        var status = await authorizationStatus()
        if status == .notDetermined {
            let granted = await requestAuthorization()
            status = granted ? .authorized : .denied
        }
        guard canDeliverNotifications(status) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Task completed"
        content.body = runCompletionBody(for: signal)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "epoch.run.complete.\(signal.runID.uuidString)",
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().addValue(request)
    }

    static func schedulePendingUserInputIfAuthorized(_ signal: AppStore.PendingUserInputSignal) async {
        var status = await authorizationStatus()
        if status == .notDetermined {
            let granted = await requestAuthorization()
            status = granted ? .authorized : .denied
        }
        guard canDeliverNotifications(status) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Response needed"
        content.body = pendingUserInputBody(for: signal)
        content.sound = .default
        content.userInfo["deepLink"] = DeepLinkCodec.sessionURL(
            projectID: signal.projectID,
            sessionID: signal.sessionID
        ).absoluteString

        let request = UNNotificationRequest(
            identifier: "epoch.pending.input.\(signal.sessionID.uuidString).\(requestIDKey(signal.requestID))",
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().addValue(request)
    }

    private static func runCompletionBody(for signal: AppStore.RunCompletionSignal) -> String {
        switch signal.status {
        case .succeeded:
            return "\(signal.projectName): run finished successfully."
        case .failed:
            return "\(signal.projectName): run finished with errors."
        case .canceled:
            return "\(signal.projectName): run was canceled."
        case .queued, .running:
            return "\(signal.projectName): run finished."
        }
    }

    private static func pendingUserInputBody(for signal: AppStore.PendingUserInputSignal) -> String {
        let prompt = signal.promptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if prompt.isEmpty {
            return "\(signal.projectName) · \(signal.sessionTitle): awaiting your response."
        }
        return "\(signal.projectName) · \(signal.sessionTitle): \(prompt)"
    }

    private static func requestIDKey(_ id: CodexRequestID) -> String {
        switch id {
        case let .string(value):
            return value.replacingOccurrences(of: " ", with: "_")
        case let .int(value):
            return String(value)
        }
    }
}

private extension UNUserNotificationCenter {
    func requestAuthorizationValue(options: UNAuthorizationOptions) async throws -> Bool {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            requestAuthorization(options: options) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func addValue(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
#endif
