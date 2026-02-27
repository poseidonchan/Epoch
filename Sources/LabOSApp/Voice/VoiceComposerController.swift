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

    @Published private(set) var phase: Phase = .idle
    @Published var lastErrorMessage: String?
    @Published var lastErrorRequiresSystemSettings = false

    var isTranscribing: Bool {
        if case .transcribing = phase {
            return true
        }
        return false
    }

    private var recorder: AVAudioRecorder?
    private var activeAudioURL: URL?
    private var permissionTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var pendingReleaseCancelledState: Bool?

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
        lastErrorMessage = nil
        lastErrorRequiresSystemSettings = false
        pendingReleaseCancelledState = nil
        phase = .recording

        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            guard let self else { return }
            let permission = await self.requestMicrophonePermissionIfNeeded()
            guard !Task.isCancelled else { return }
            guard permission.granted else {
                self.phase = .idle
                self.lastErrorRequiresSystemSettings = permission.requiresSystemSettings
                self.lastErrorMessage = "Microphone permission is required for voice input."
                return
            }

            do {
                try self.startRecorder()
                if let pendingCancel = self.pendingReleaseCancelledState {
                    self.finalizeRecording(cancelledByGesture: pendingCancel)
                }
            } catch {
                self.phase = .idle
                self.lastErrorRequiresSystemSettings = false
                self.lastErrorMessage = error.localizedDescription
            }
        }
    }

    func setCancelArmed(_ armed: Bool) {
        switch phase {
        case .recording, .cancelArmed:
            phase = armed ? .cancelArmed : .recording
        case .idle, .transcribing:
            break
        }
    }

    func endRecording(cancelledByGesture: Bool) {
        switch phase {
        case .recording, .cancelArmed:
            break
        case .idle, .transcribing:
            return
        }

        if recorder == nil {
            pendingReleaseCancelledState = cancelledByGesture
            if permissionTask == nil {
                phase = .idle
            }
            return
        }

        finalizeRecording(cancelledByGesture: cancelledByGesture)
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
        pendingReleaseCancelledState = nil
        lastErrorRequiresSystemSettings = false
        phase = .idle
    }

    func voiceState(isConfigured: Bool) -> InlineComposerView.VoiceState {
        guard isConfigured else { return .unavailable }
        switch phase {
        case .idle:
            return .idle
        case .recording:
            return .recording
        case .cancelArmed:
            return .cancelArmed
        case let .transcribing(progress):
            return .transcribing(progress: progress)
        }
    }

    private func startRecorder() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("labos-voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        activeAudioURL = outputURL

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
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
        pendingReleaseCancelledState = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let audioURL = activeAudioURL else {
            phase = .idle
            return
        }

        if cancelledByGesture {
            try? FileManager.default.removeItem(at: audioURL)
            activeAudioURL = nil
            phase = .idle
            return
        }

        beginTranscription(for: audioURL)
    }

    private func beginTranscription(for audioURL: URL) {
        guard let transcribeAction else {
            phase = .idle
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
            }

            do {
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
                self.lastErrorRequiresSystemSettings = false
                self.lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
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

    private func requestMicrophonePermissionIfNeeded() async -> MicrophonePermissionOutcome {
        let permission = AVAudioSession.sharedInstance().recordPermission
        switch permission {
        case .granted:
            return MicrophonePermissionOutcome(granted: true, requiresSystemSettings: false)
        case .denied:
            return MicrophonePermissionOutcome(granted: false, requiresSystemSettings: true)
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(
                        returning: MicrophonePermissionOutcome(
                            granted: granted,
                            requiresSystemSettings: !granted
                        )
                    )
                }
            }
        @unknown default:
            return MicrophonePermissionOutcome(granted: false, requiresSystemSettings: false)
        }
    }
}
#endif
