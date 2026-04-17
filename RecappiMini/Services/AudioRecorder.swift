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
    @Published var selectedApp: AudioApp? {
        didSet { persistSelectedApp() }
    }
    @Published var recordingAppName: String?

    private static let selectedAppKey = "RecappiMini.selectedApp"

    private func persistSelectedApp() {
        let defaults = UserDefaults.standard
        if let id = selectedApp?.id {
            defaults.set(id, forKey: Self.selectedAppKey)
        } else {
            defaults.removeObject(forKey: Self.selectedAppKey)
        }
    }
    /// Last completed recording's folder — kept across error state so UI can offer Open Folder / Retry.
    @Published var lastSessionDir: URL?
    @Published var lastDuration: Int = 0

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var sessionDir: URL?
    private var timer: Timer?
    private var streamOutput: AudioStreamOutput?

    var currentSessionDir: URL? { sessionDir }

    /// Scan all running GUI apps
    func refreshApps() async {
        do {
            let content = try await SCShareableContent.current
            let selfBundleID = Bundle.main.bundleIdentifier ?? "com.recappi.mini"
            let apps = content.applications.compactMap { scApp -> AudioApp? in
                let bid = scApp.bundleIdentifier
                guard !bid.isEmpty else { return nil }
                guard bid != selfBundleID else { return nil }
                // Skip system/background processes
                guard !bid.hasPrefix("com.apple.") || isNotableAppleApp(bid) else { return nil }
                // Skip helper/agent processes (often show as sub-processes)
                let name = scApp.applicationName
                guard !name.isEmpty, !name.contains("Agent"), !name.contains("Helper") else { return nil }
                // Get app icon, pre-scale to 16px for menu use
                let rawIcon = NSWorkspace.shared.icon(forFile:
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)?.path ?? "")
                rawIcon.size = NSSize(width: 16, height: 16)
                return AudioApp(id: bid, name: name, icon: rawIcon, scApp: scApp)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.runningApps = apps

            // Restore last selection if the saved app is now visible in the list.
            // Only applies when the user hasn't already chosen something this session.
            if selectedApp == nil,
               let savedId = UserDefaults.standard.string(forKey: Self.selectedAppKey),
               let restored = apps.first(where: { $0.id == savedId }) {
                selectedApp = restored
            }
        } catch {
            self.runningApps = []
        }
    }

    func startRecording() async throws {
        guard state == .idle else { return }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

        let sessionDir = try RecordingStore.createSessionDirectory()
        self.sessionDir = sessionDir

        let audioURL = RecordingStore.audioFileURL(in: sessionDir)
        let writer = try AVAssetWriter(url: audioURL, fileType: .m4a)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        self.assetWriter = writer
        self.audioInput = input

        let output = AudioStreamOutput(writer: writer, input: input)
        self.streamOutput = output

        // Build filter: single app or whole display
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

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        self.stream = stream

        try await stream.startCapture()
        writer.startWriting()

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

        try await stream?.stopCapture()
        stream = nil
        streamOutput = nil

        audioInput?.markAsFinished()
        await assetWriter?.finishWriting()

        guard let sessionDir = self.sessionDir else {
            throw RecorderError.noSessionDir
        }

        self.lastSessionDir = sessionDir
        self.lastDuration = elapsedSeconds
        return sessionDir
    }

    func reset() {
        state = .idle
        elapsedSeconds = 0
        sessionDir = nil
        stream = nil
        assetWriter = nil
        audioInput = nil
        streamOutput = nil
        recordingAppName = nil
        lastSessionDir = nil
        lastDuration = 0
    }

    // MARK: - High-level flow (shared by UI buttons and global hotkey)

    /// Start recording and route errors into `.error`.
    func startFlow() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startRecording()
            } catch {
                self.state = .error(message: error.localizedDescription)
            }
        }
    }

    /// Stop, then transcribe + optionally summarize.
    func stopFlow() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let duration = self.elapsedSeconds
                let sessionDir = try await self.stopRecording()
                await self.processAudio(sessionDir: sessionDir, duration: duration)
            } catch {
                self.state = .error(message: error.localizedDescription)
            }
        }
    }

    /// Re-run transcribe+summarize on the last saved session.
    func retryFlow() {
        guard let dir = lastSessionDir else { return }
        let duration = lastDuration
        Task { [weak self] in
            await self?.processAudio(sessionDir: dir, duration: duration)
        }
    }

    /// idle → start, recording → stop, otherwise no-op. Used by the global hotkey.
    func toggleRecording() {
        switch state {
        case .idle: startFlow()
        case .recording: stopFlow()
        default: break
        }
    }

    private func processAudio(sessionDir: URL, duration: Int) async {
        do {
            let config = AppConfig.shared
            let transcriber = createTranscriber(config: config)

            state = .transcribing
            let audioURL = RecordingStore.audioFileURL(in: sessionDir)
            let transcript = try await transcriber.transcribe(audioURL: audioURL)
            try RecordingStore.saveTranscript(transcript, in: sessionDir)

            var summary: String? = nil
            if config.selectedProvider != .none {
                state = .summarizing
                let summarizer = createSummarizer(config: config)
                let s = try await summarizer.summarize(transcript: transcript)
                if !s.isEmpty {
                    try RecordingStore.saveSummary(s, in: sessionDir)
                    summary = s
                }
            }

            state = .done(result: RecordingResult(
                folderURL: sessionDir,
                transcript: transcript,
                summary: summary,
                duration: duration
            ))
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }

    /// Notable Apple apps that users might want to record
    private func isNotableAppleApp(_ bid: String) -> Bool {
        let notable: Set<String> = [
            "com.apple.Safari",
            "com.apple.FaceTime",
            "com.apple.Music",
        ]
        return notable.contains(bid)
    }
}

final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
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

enum RecorderError: LocalizedError {
    case noDisplay
    case notRecording
    case noSessionDir

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found for audio capture"
        case .notRecording: return "Not currently recording"
        case .noSessionDir: return "No session directory"
        }
    }
}
