import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

struct AudioApp: Identifiable, Hashable {
    let id: String  // bundle ID
    let name: String
    let icon: NSImage?
    let scApp: SCRunningApplication

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var state: RecorderState = .idle
    @Published var elapsedSeconds: Int = 0
    @Published var runningApps: [AudioApp] = []
    @Published var selectedApp: AudioApp?
    @Published var recordingAppName: String?

    // --- System audio (ScreenCaptureKit) pipeline ---
    private var stream: SCStream?
    private var systemWriter: AVAssetWriter?
    private var systemInput: AVAssetWriterInput?
    private var systemOutput: SystemAudioOutput?

    // --- Microphone (AVCaptureSession) pipeline ---
    private var micSession: AVCaptureSession?
    private var micWriter: AVAssetWriter?
    private var micInput: AVAssetWriterInput?
    private var micOutput: MicAudioOutput?

    private var sessionDir: URL?
    private var timer: Timer?

    var currentSessionDir: URL? { sessionDir }

    // MARK: - App discovery

    func refreshApps() async {
        do {
            let content = try await SCShareableContent.current
            let selfBundleID = Bundle.main.bundleIdentifier ?? "com.recappi.mini"
            let apps = content.applications.compactMap { scApp -> AudioApp? in
                let bid = scApp.bundleIdentifier
                guard !bid.isEmpty else { return nil }
                guard bid != selfBundleID else { return nil }
                guard !bid.hasPrefix("com.apple.") || isNotableAppleApp(bid) else { return nil }
                let name = scApp.applicationName
                guard !name.isEmpty, !name.contains("Agent"), !name.contains("Helper") else { return nil }
                let rawIcon = NSWorkspace.shared.icon(forFile:
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)?.path ?? "")
                rawIcon.size = NSSize(width: 16, height: 16)
                return AudioApp(id: bid, name: name, icon: rawIcon, scApp: scApp)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.runningApps = apps
        } catch {
            self.runningApps = []
        }
    }

    // MARK: - Start / Stop

    func startRecording() async throws {
        guard state == .idle else { return }

        try await requestMicrophoneAccessIfNeeded()

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

        let sessionDir = try RecordingStore.createSessionDirectory()
        self.sessionDir = sessionDir

        // Intermediate files; merged into recording.m4a at stop.
        let systemURL = sessionDir.appendingPathComponent("system.m4a")
        let micURL = sessionDir.appendingPathComponent("mic.m4a")

        // Both sources write at native 48kHz stereo 128kbps AAC.
        // Recompression to 16kHz mono 32kbps happens during the merge step so
        // we keep raw quality in case the merge fails and the user needs the
        // intermediates.
        let sourceSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000,
        ]

        // --- System audio pipeline ---
        let sysWriter = try AVAssetWriter(url: systemURL, fileType: .m4a)
        let sysInput = AVAssetWriterInput(mediaType: .audio, outputSettings: sourceSettings)
        sysInput.expectsMediaDataInRealTime = true
        sysWriter.add(sysInput)
        self.systemWriter = sysWriter
        self.systemInput = sysInput
        let sysOut = SystemAudioOutput(writer: sysWriter, input: sysInput)
        self.systemOutput = sysOut

        let filter: SCContentFilter
        if let app = selectedApp,
           let liveApp = content.applications.first(where: { $0.bundleIdentifier == app.id }) {
            filter = SCContentFilter(display: display, including: [liveApp], exceptingWindows: [])
            recordingAppName = app.name
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            recordingAppName = nil
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try scStream.addStreamOutput(sysOut, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        self.stream = scStream

        // --- Microphone pipeline ---
        let mcWriter = try AVAssetWriter(url: micURL, fileType: .m4a)
        let mcInput = AVAssetWriterInput(mediaType: .audio, outputSettings: sourceSettings)
        mcInput.expectsMediaDataInRealTime = true
        mcWriter.add(mcInput)
        self.micWriter = mcWriter
        self.micInput = mcInput

        let captureSession = AVCaptureSession()
        guard let micDevice = AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.noMicrophone
        }
        let deviceInput = try AVCaptureDeviceInput(device: micDevice)
        guard captureSession.canAddInput(deviceInput) else {
            throw RecorderError.micSetupFailed
        }
        captureSession.addInput(deviceInput)

        let mcOut = MicAudioOutput(writer: mcWriter, input: mcInput)
        let captureOutput = AVCaptureAudioDataOutput()
        captureOutput.setSampleBufferDelegate(mcOut, queue: DispatchQueue(label: "mic.capture"))
        guard captureSession.canAddOutput(captureOutput) else {
            throw RecorderError.micSetupFailed
        }
        captureSession.addOutput(captureOutput)
        self.micSession = captureSession
        self.micOutput = mcOut

        // --- Start both pipelines ---
        try await scStream.startCapture()
        sysWriter.startWriting()
        mcWriter.startWriting()
        captureSession.startRunning()

        self.state = .recording
        self.elapsedSeconds = 0
        self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    func stopRecording() async throws -> URL {
        guard state == .recording else {
            throw RecorderError.notRecording
        }

        self.state = .stopping
        self.timer?.invalidate()
        self.timer = nil

        // Stop system audio stream
        try await stream?.stopCapture()
        stream = nil
        systemOutput = nil
        systemInput?.markAsFinished()
        await systemWriter?.finishWriting()

        // Stop microphone capture
        micSession?.stopRunning()
        micSession = nil
        micOutput = nil
        micInput?.markAsFinished()
        await micWriter?.finishWriting()

        guard let sessionDir = self.sessionDir else {
            throw RecorderError.noSessionDir
        }

        // Merge system + mic into a single compressed recording.m4a.
        let systemURL = sessionDir.appendingPathComponent("system.m4a")
        let micURL = sessionDir.appendingPathComponent("mic.m4a")
        let mergedURL = RecordingStore.audioFileURL(in: sessionDir)

        do {
            try await AudioMixer.mix(
                sources: [systemURL, micURL],
                to: mergedURL
            )
            // Only delete intermediates on success; on failure the caller
            // (stop/retry flow) can still inspect the two raw files.
            try? FileManager.default.removeItem(at: systemURL)
            try? FileManager.default.removeItem(at: micURL)
        } catch {
            // Merge failed — leave intermediates for debugging and surface the
            // error to the caller. Transcription downstream needs recording.m4a
            // to exist, so rethrow.
            throw error
        }

        return sessionDir
    }

    func reset() {
        state = .idle
        elapsedSeconds = 0
        sessionDir = nil
        stream = nil
        systemWriter = nil
        systemInput = nil
        systemOutput = nil
        micSession = nil
        micWriter = nil
        micInput = nil
        micOutput = nil
        recordingAppName = nil
    }

    // MARK: - Permissions

    private func requestMicrophoneAccessIfNeeded() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw RecorderError.micDenied }
        case .denied, .restricted:
            throw RecorderError.micDenied
        @unknown default:
            throw RecorderError.micDenied
        }
    }

    private func isNotableAppleApp(_ bid: String) -> Bool {
        let notable: Set<String> = [
            "com.apple.Safari",
            "com.apple.FaceTime",
            "com.apple.Music",
        ]
        return notable.contains(bid)
    }
}

// MARK: - System audio receiver

final class SystemAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var isWriterStarted = false

    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else { return }
        guard writer.status == .writing else { return }

        if !isWriterStarted {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: timestamp)
            isWriterStarted = true
        }

        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}

// MARK: - Microphone receiver

final class MicAudioOutput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var isWriterStarted = false

    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid else { return }
        guard writer.status == .writing else { return }

        if !isWriterStarted {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: timestamp)
            isWriterStarted = true
        }

        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}

// MARK: - Errors

enum RecorderError: LocalizedError {
    case noDisplay
    case noMicrophone
    case micDenied
    case micSetupFailed
    case notRecording
    case noSessionDir
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found for audio capture"
        case .noMicrophone: return "No microphone found"
        case .micDenied: return "Microphone access denied. Enable in System Settings > Privacy & Security > Microphone"
        case .micSetupFailed: return "Couldn't set up microphone capture"
        case .notRecording: return "Not currently recording"
        case .noSessionDir: return "No session directory"
        case .exportFailed: return "Failed to merge audio sources"
        }
    }
}
