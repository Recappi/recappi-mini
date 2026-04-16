import AVFoundation
import CoreMedia
import ScreenCaptureKit

// Known meeting app bundle IDs
let meetingAppBundleIDs: Set<String> = [
    "us.zoom.xos",                          // Zoom
    "com.microsoft.teams",                   // Microsoft Teams
    "com.microsoft.teams2",                  // Microsoft Teams (new)
    "com.cisco.webexmeetingsapp",            // Webex
    "com.google.Chrome",                     // Chrome (for Google Meet)
    "com.apple.Safari",                      // Safari (for Google Meet)
    "org.mozilla.firefox",                   // Firefox
    "com.microsoft.edgemac",                 // Edge
    "com.brave.Browser",                     // Brave
    "com.slack.Slack",                       // Slack huddles
    "com.tinyspeck.slackmacgap",             // Slack (older)
    "com.discord.Discord",                   // Discord
    "com.skype.skype",                       // Skype
    "com.facetime",                          // FaceTime
    "com.apple.FaceTime",                    // FaceTime
]

struct AudioApp: Identifiable, Hashable {
    let id: String  // bundle ID
    let name: String
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
    @Published var detectedApps: [AudioApp] = []
    @Published var selectedApp: AudioApp?
    @Published var recordingAppName: String?

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var sessionDir: URL?
    private var timer: Timer?
    private var streamOutput: AudioStreamOutput?

    var currentSessionDir: URL? { sessionDir }

    /// Scan for running meeting/audio apps
    func refreshApps() async {
        do {
            let content = try await SCShareableContent.current
            let apps = content.applications.compactMap { app -> AudioApp? in
                let bundleID = app.bundleIdentifier
                guard meetingAppBundleIDs.contains(bundleID) else { return nil }
                return AudioApp(id: bundleID, name: app.applicationName, scApp: app)
            }
            self.detectedApps = apps
        } catch {
            self.detectedApps = []
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
            // Record only this app's audio
            filter = SCContentFilter(display: display, including: [liveApp], exceptingWindows: [])
            recordingAppName = app.name
            print("[RecappiMini] Recording audio from: \(app.name) (\(app.id))")
        } else {
            // Fallback: record all system audio
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            recordingAppName = nil
            print("[RecappiMini] Recording all system audio")
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
}

// Separate class for SCStreamOutput to avoid Sendable issues
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
