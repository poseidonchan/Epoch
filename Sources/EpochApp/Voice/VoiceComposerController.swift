#if os(iOS)
import AVFoundation
import Foundation

@MainActor
final class VoiceComposerController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case cancelArmed
        case transcribing(progress: Double)
    }

    enum CaptureMode: Equatable {
        case none
        case hold
        case tapLocked
    }

    enum PendingReleaseAction: Equatable {
        case keepRecording
        case submit
        case cancel
    }

    struct ReleaseDecision: Equatable {
        var action: PendingReleaseAction
        var nextMode: CaptureMode
    }

    static let tapVsHoldDecisionThreshold: TimeInterval = 0.22

    @Published private(set) var phase: Phase = .idle
    @Published var lastErrorMessage: String?
    @Published var lastErrorRequiresSystemSettings = false

    var isTranscribing: Bool {
        if case .transcribing = phase {
            return true
        }
        return false
    }

    private let tapVsHoldThreshold: TimeInterval = VoiceComposerController.tapVsHoldDecisionThreshold
    private let fileReadyTimeoutSeconds: TimeInterval = 1.6

    private var recorder: AVAudioRecorder?
    private var activeAudioURL: URL?
    private var permissionTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?

    private var captureMode: CaptureMode = .none
    private var pendingReleaseAction: PendingReleaseAction?

    private var transcribeAction: ((URL) async throws -> String)?
    private var onTranscription: ((String) -> Void)?

    func configure(
        transcribeAction: @escaping (URL) async throws -> String,
        onTranscription: @escaping (String) -> Void
    ) {
        self.transcribeAction = transcribeAction
        self.onTranscription = onTranscription
    }

    func beginRecording() {
        guard case .idle = phase else { return }

        guard hasMicrophoneUsageDescription() else {
            phase = .idle
            lastErrorRequiresSystemSettings = false
            lastErrorMessage = "Microphone is not configured for this build. Reinstall the latest app build and try again."
            return
        }

        lastErrorMessage = nil
        lastErrorRequiresSystemSettings = false
        captureMode = .hold
        pendingReleaseAction = nil
        phase = .recording

        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let permission = await self.requestMicrophonePermissionIfNeeded()
            guard !Task.isCancelled else { return }
            guard permission.granted else {
                self.phase = .idle
                self.captureMode = .none
                self.lastErrorRequiresSystemSettings = permission.requiresSystemSettings
                self.lastErrorMessage = "Microphone permission is required for voice input."
                return
            }

            do {
                try self.startRecorder()
                self.applyPendingReleaseActionIfNeededAfterRecorderStart()
            } catch {
                self.phase = .idle
                self.captureMode = .none
                self.pendingReleaseAction = nil
                self.lastErrorRequiresSystemSettings = false
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    func setCancelArmed(_ armed: Bool) {
        guard captureMode != .tapLocked else {
            if phase != .recording {
                phase = .recording
            }
            return
        }

        switch phase {
        case .recording, .cancelArmed:
            phase = armed ? .cancelArmed : .recording
        case .idle, .transcribing:
            break
        }
    }

    func endRecording(cancelledByGesture: Bool, pressDuration: TimeInterval) {
        switch phase {
        case .recording, .cancelArmed:
            break
        case .idle, .transcribing:
            return
        }

        let releaseResolution = Self.resolveReleaseDecision(
            captureMode: captureMode,
            cancelledByGesture: cancelledByGesture,
            pressDuration: pressDuration,
            threshold: tapVsHoldThreshold
        )
        captureMode = releaseResolution.nextMode

        if recorder == nil {
            pendingReleaseAction = releaseResolution.action
            if permissionTask == nil {
                phase = .idle
                captureMode = .none
                pendingReleaseAction = nil
            } else if releaseResolution.nextMode == .tapLocked {
                phase = .recording
            }
            return
        }

        applyReleaseAction(releaseResolution.action)
    }

    func cancelAll() {
        permissionTask?.cancel()
        permissionTask = nil
        transcribeTask?.cancel()
        transcribeTask = nil
        progressTask?.cancel()
        progressTask = nil
        recorder?.stop()
        recorder = nil
        activeAudioURL = nil
        captureMode = .none
        pendingReleaseAction = nil
        lastErrorRequiresSystemSettings = false
        phase = .idle
    }

    func voiceState(isConfigured: Bool) -> InlineComposerView.VoiceState {
        guard isConfigured else { return .unavailable }
        switch phase {
        case .idle:
            return .idle
        case .recording:
            return captureMode == .tapLocked ? .recordingLocked : .recording
        case .cancelArmed:
            return .cancelArmed
        case let .transcribing(progress):
            return .transcribing(progress: progress)
        }
    }

    static func resolveReleaseDecision(
        captureMode: CaptureMode,
        cancelledByGesture: Bool,
        pressDuration: TimeInterval,
        threshold: TimeInterval
    ) -> ReleaseDecision {
        switch captureMode {
        case .tapLocked:
            return ReleaseDecision(action: .submit, nextMode: .none)
        case .hold, .none:
            if cancelledByGesture {
                return ReleaseDecision(action: .cancel, nextMode: .none)
            }
            if pressDuration < threshold {
                return ReleaseDecision(action: .keepRecording, nextMode: .tapLocked)
            }
            return ReleaseDecision(action: .submit, nextMode: .none)
        }
    }

    private func applyPendingReleaseActionIfNeededAfterRecorderStart() {
        guard let action = pendingReleaseAction else { return }
        pendingReleaseAction = nil
        applyReleaseAction(action)
    }

    private func applyReleaseAction(_ action: PendingReleaseAction) {
        switch action {
        case .keepRecording:
            phase = .recording
        case .submit:
            finalizeRecording(cancelledByGesture: false)
        case .cancel:
            finalizeRecording(cancelledByGesture: true)
        }
    }

    private func startRecorder() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("epoch-voice-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        activeAudioURL = outputURL

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw NSError(
                domain: "VoiceComposerController",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start audio recording."]
            )
        }
        self.recorder = recorder
    }

    private func finalizeRecording(cancelledByGesture: Bool) {
        recorder?.stop()
        recorder = nil
        permissionTask?.cancel()
        permissionTask = nil
        pendingReleaseAction = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let audioURL = activeAudioURL else {
            phase = .idle
            captureMode = .none
            return
        }

        if cancelledByGesture {
            try? FileManager.default.removeItem(at: audioURL)
            activeAudioURL = nil
            captureMode = .none
            phase = .idle
            return
        }

        beginTranscription(for: audioURL)
    }

    private func beginTranscription(for audioURL: URL) {
        guard let transcribeAction else {
            phase = .idle
            captureMode = .none
            lastErrorMessage = "Voice transcription is not configured."
            return
        }

        phase = .transcribing(progress: 0.02)
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                let predicted = self.predictedProgress(elapsedSeconds: elapsed)
                self.phase = .transcribing(progress: predicted)
                try? await Task.sleep(for: .milliseconds(35))
            }
        }

        transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: audioURL)
                self.activeAudioURL = nil
                self.captureMode = .none
            }

            do {
                try await self.waitForRecordedFileReady(at: audioURL, timeout: self.fileReadyTimeoutSeconds)
                let text = try await transcribeAction(audioURL)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    throw NSError(
                        domain: "VoiceComposerController",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Transcription returned empty text."]
                    )
                }
                await self.completeProgressAndReset()
                self.onTranscription?(trimmed)
            } catch {
                self.progressTask?.cancel()
                self.progressTask = nil
                self.phase = .idle
                self.captureMode = .none
                self.lastErrorRequiresSystemSettings = false
                self.lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func waitForRecordedFileReady(at url: URL, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(max(0.2, timeout))
        while Date() < deadline {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        throw NSError(
            domain: "VoiceComposerController",
            code: -3,
            userInfo: [NSLocalizedDescriptionKey: "Recording file was not ready. Please try again."]
        )
    }

    private func completeProgressAndReset() async {
        progressTask?.cancel()
        progressTask = nil

        var current = transcriptionProgress
        for _ in 0 ..< 4 {
            current = current + (1 - current) * 0.55
            phase = .transcribing(progress: current)
            try? await Task.sleep(for: .milliseconds(22))
        }
        phase = .transcribing(progress: 1)
        try? await Task.sleep(for: .milliseconds(70))
        phase = .idle
    }

    private var transcriptionProgress: Double {
        if case let .transcribing(progress) = phase {
            return min(max(progress, 0), 1)
        }
        return 0
    }

    private func predictedProgress(elapsedSeconds: TimeInterval) -> Double {
        if elapsedSeconds <= 2 {
            let t = min(max(elapsedSeconds / 2, 0), 1)
            let eased = 1 - pow(1 - t, 3)
            return min(max(0.05 + 0.83 * eased, 0.05), 0.88)
        }
        let overflow = elapsedSeconds - 2
        let nearEnd = 0.88 + 0.10 * (1 - exp(-overflow / 3.2))
        return min(max(nearEnd, 0.88), 0.98)
    }

    private struct MicrophonePermissionOutcome {
        var granted: Bool
        var requiresSystemSettings: Bool
    }

    private func hasMicrophoneUsageDescription() -> Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        return !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func requestMicrophonePermissionIfNeeded() async -> MicrophonePermissionOutcome {
        let permission = AVAudioApplication.shared.recordPermission
        switch permission {
        case .granted:
            return MicrophonePermissionOutcome(granted: true, requiresSystemSettings: false)
        case .denied:
            return MicrophonePermissionOutcome(granted: false, requiresSystemSettings: true)
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            return MicrophonePermissionOutcome(granted: granted, requiresSystemSettings: !granted)
        @unknown default:
            return MicrophonePermissionOutcome(granted: false, requiresSystemSettings: false)
        }
    }
}
#endif
