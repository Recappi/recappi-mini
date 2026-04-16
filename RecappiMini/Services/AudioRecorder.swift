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
                // Get app icon
                let icon = NSWorkspace.shared.icon(forFile:
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)?.path ?? "")
                return AudioApp(id: bid, name: name, icon: icon, scApp: scApp)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.runningApps = apps
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
