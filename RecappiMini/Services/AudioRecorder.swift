import Accelerate
import AVFoundation
import AppKit
import CoreMedia
@preconcurrency import ScreenCaptureKit

struct AudioApp: Identifiable, Hashable {
    enum Bucket: Int, Sendable, Comparable {
        case meeting = 0
        case browser = 1
        case other = 2
        static func < (lhs: Bucket, rhs: Bucket) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String  // bundle ID
    let name: String
    let icon: NSImage?
    let scApp: SCRunningApplication
    let bucket: Bucket
    /// True when AudioActivityMonitor sees this bundle currently producing
    /// output audio. Active apps float to the top of the picker.
    var isActive: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id
    }
}

/// Bundle-ID whitelists for smart sorting. Helpers / renderers are filtered
/// out at the refresh step, so we classify by the user-visible parent bundle.
private enum AudioAppCategories {
    static let meetingBundles: Set<String> = [
        "us.zoom.xos",
        "us.zoom.Zoom",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",         // Slack (huddles)
        "com.hnc.Discord",
        "com.cisco.webexmeetingsapp",
        "com.cisco.webexmeetingsapp.WebexApp",
        "com.apple.FaceTime",
        "com.loom.desktop",
    ]

    static let browserBundles: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "company.thebrowser.Browser",        // Arc
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    static func bucket(for bundleID: String) -> AudioApp.Bucket {
        if meetingBundles.contains(bundleID) { return .meeting }
        if browserBundles.contains(bundleID) { return .browser }
        return .other
    }
}

/// Collapses child bundle IDs onto their parent. Chrome-style multi-process
/// apps emit audio from `.helper(.Renderer)` / `.Agent` subprocesses; the
/// user recognises the app by its parent bundle, so both the selector and
/// the activity monitor need the same canonicalisation.
enum BundleCollapser {
    private static let markers: [String] = [
        ".helper", ".Helper",
        ".renderer", ".Renderer",
        ".agent", ".Agent",
        ".plugin_host",
    ]

    static func parent(of bundleID: String) -> String {
        for marker in markers {
            if let range = bundleID.range(of: marker) {
                return String(bundleID[..<range.lowerBound])
            }
        }
        return bundleID
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var state: RecorderState = .idle
    @Published var elapsedSeconds: Int = 0
    @Published var runningApps: [AudioApp] = []
    @Published var selectedApp: AudioApp?
    @Published var recordingAppName: String?
    @Published var audioLevel: Float = 0
    @Published var audioSpectrumLevels: [Float] = Array(repeating: 0, count: AudioRecorder.spectrumBucketCount)
    @Published var audioLevelHistory: [Float] = Array(repeating: 0, count: AudioRecorder.spectrumBucketCount)
    /// Session directory of the most-recent (or in-progress) recording.
    /// Populated on stop and kept through processing + error states so the
    /// UI can offer Retry / Show without stashing state at the view layer.
    @Published var lastSessionDir: URL?

    // --- System audio (ScreenCaptureKit) pipeline ---
    /// Hot-audio signal surfaced to the picker. Owned here so the UI
    /// observes the same refresh clock as runningApps updates.
    let activityMonitor = AudioActivityMonitor()

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
    /// Timestamp of the last `audioLevel` publish; capped at 30 Hz so
    /// SwiftUI doesn't burn a re-render per ScreenCaptureKit buffer.
    private var lastLevelPublish: CFTimeInterval = 0
    private var lastHistoryPublish: CFTimeInterval = 0
    private let uiTestMode = UITestModeConfiguration.shared

    static let spectrumBucketCount = AudioSpectrumConfiguration.bucketCount
    private static let historySampleInterval: CFTimeInterval = 0.18

    var currentSessionDir: URL? { sessionDir }

    // MARK: - App discovery

    func refreshApps() async {
        do {
            let content = try await SCShareableContent.current
            let selfBundleID = Bundle.main.bundleIdentifier ?? "com.recappi.mini"

            // Group SCRunningApplications by their "owning" bundle — Chrome
            // and similar emit audio from child helpers like
            // com.google.Chrome.helper(.Renderer). We collapse those onto the
            // parent bundle id so the list and selection stay at the app
            // level the user recognises.
            var byParent: [String: SCRunningApplication] = [:]
            for scApp in content.applications {
                let bid = scApp.bundleIdentifier
                guard !bid.isEmpty else { continue }
                let parent = Self.parentBundle(of: bid)
                guard parent != selfBundleID else { continue }
                guard !parent.hasPrefix("com.apple.") || isNotableAppleApp(parent) else { continue }
                // Prefer the parent-bundle instance if we see it; otherwise
                // keep the first helper we found so we at least have an
                // SCRunningApplication to stream through.
                if byParent[parent] == nil || scApp.bundleIdentifier == parent {
                    byParent[parent] = scApp
                }
            }

            let active = activityMonitor.activeBundleIDs
            let apps = byParent.compactMap { (parentBid, scApp) -> AudioApp? in
                let name = Self.displayName(for: parentBid, fallback: scApp.applicationName)
                guard !name.isEmpty else { return nil }
                let rawIcon = NSWorkspace.shared.icon(forFile:
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: parentBid)?.path ?? "")
                rawIcon.size = NSSize(width: 16, height: 16)
                return AudioApp(
                    id: parentBid,
                    name: name,
                    icon: rawIcon,
                    scApp: scApp,
                    bucket: AudioAppCategories.bucket(for: parentBid),
                    isActive: active.contains(parentBid)
                )
            }
            .sorted(by: Self.sortOrder)

            self.runningApps = apps
        } catch {
            self.runningApps = []
        }
    }

    /// Active apps float above inactive; within each active/inactive group
    /// sort by the static bucket (meeting → browser → other) then name.
    static func sortOrder(_ lhs: AudioApp, _ rhs: AudioApp) -> Bool {
        if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
        if lhs.bucket != rhs.bucket { return lhs.bucket < rhs.bucket }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    /// Re-apply the latest activity snapshot without a full SCShareableContent
    /// round-trip. Called when AudioActivityMonitor publishes a change.
    func applyActivity(_ active: Set<String>) {
        var mutated = runningApps
        var anyChanged = false
        for i in mutated.indices {
            let shouldBeActive = active.contains(mutated[i].id)
            if mutated[i].isActive != shouldBeActive {
                mutated[i].isActive = shouldBeActive
                anyChanged = true
            }
        }
        if anyChanged {
            runningApps = mutated.sorted(by: Self.sortOrder)
        }
    }

    /// Shared wrapper so other services (AudioActivityMonitor) can collapse
    /// helper bundle ids the same way.
    static func parentBundle(of bundleID: String) -> String {
        BundleCollapser.parent(of: bundleID)
    }

    /// Prefer the real display name from the application bundle so e.g.
    /// "Google Chrome Helper (Renderer)" collapses to "Google Chrome".
    private static func displayName(for bundleID: String, fallback: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
               ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
               ?? (bundle.infoDictionary?["CFBundleName"] as? String) {
            return name
        }
        return fallback
    }

    // MARK: - Start / Stop

    func startRecording() async throws {
        guard state == .idle else { return }
        state = .starting

        if uiTestMode.isEnabled {
            try startUITestRecording()
            return
        }

        try await requestMicrophoneAccessIfNeeded()
        guard CapturePermissionPrimer.shared.hasScreenCaptureAccess() else {
            throw RecorderError.screenCaptureDenied
        }

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
        // The merge step now preserves that higher-quality profile in the
        // canonical `recording.m4a`; any 16kHz mono WAV conversion is deferred
        // until a backend compatibility fallback actually needs it.
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
        sysOut.onMeterFrame = { [weak self] frame in
            self?.ingestMeterFrame(frame)
        }
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
        mcOut.onMeterFrame = { [weak self] frame in
            self?.ingestMeterFrame(frame)
        }
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

        self.audioLevel = 0
        self.audioSpectrumLevels = Array(repeating: 0, count: Self.spectrumBucketCount)
        self.audioLevelHistory = Array(repeating: 0, count: Self.spectrumBucketCount)
        self.lastLevelPublish = 0
        self.lastHistoryPublish = 0
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

        self.state = .processing(.savingAudio)
        self.timer?.invalidate()
        self.timer = nil

        if uiTestMode.isEnabled {
            return try stopUITestRecording()
        }

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
        self.lastSessionDir = sessionDir

        // Merge system + mic into a single high-quality recording.m4a.
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

    /// Merge the latest peak + spectrum from either audio source into the
    /// live recording meter. Called from the capture queues — we hop to the
    /// main actor, take the max of system + mic, and cap publish rate to 30 Hz.
    nonisolated func ingestMeterFrame(_ frame: AudioMeterFrame) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()

            // Hold peak with light decay so a single-buffer spike still reads
            // visually over the ~33ms publish window.
            let smoothed = max(self.audioLevel * 0.82, frame.peak)

            if now - self.lastLevelPublish >= 1.0 / 30.0 {
                self.lastLevelPublish = now
                self.audioLevel = smoothed

                let incoming = normalizeSpectrum(frame.bands)
                let decayed = self.audioSpectrumLevels.map { $0 * 0.72 }
                self.audioSpectrumLevels = zip(decayed, incoming).map(max)
            }

            if now - self.lastHistoryPublish >= Self.historySampleInterval {
                self.lastHistoryPublish = now
                let historyValue = min(1, pow(max(smoothed, 0), 0.75))
                var history = self.audioLevelHistory
                history.append(historyValue)
                if history.count > Self.spectrumBucketCount {
                    history.removeFirst(history.count - Self.spectrumBucketCount)
                }
                self.audioLevelHistory = history
            }
        }
    }

    func reset() {
        state = .idle
        elapsedSeconds = 0
        audioLevel = 0
        audioSpectrumLevels = Array(repeating: 0, count: Self.spectrumBucketCount)
        audioLevelHistory = Array(repeating: 0, count: Self.spectrumBucketCount)
        lastLevelPublish = 0
        lastHistoryPublish = 0
        sessionDir = nil
        lastSessionDir = nil
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

    private func normalizeSpectrum(_ levels: [Float]) -> [Float] {
        if levels.count == Self.spectrumBucketCount {
            return levels
        }
        if levels.count > Self.spectrumBucketCount {
            return Array(levels.prefix(Self.spectrumBucketCount))
        }
        return levels + Array(repeating: 0, count: Self.spectrumBucketCount - levels.count)
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

    private func startUITestRecording() throws {
        guard let fixturePath = uiTestMode.audioFixturePath, !fixturePath.isEmpty else {
            throw RecorderError.missingUITestFixture
        }
        guard FileManager.default.fileExists(atPath: fixturePath) else {
            throw RecorderError.missingUITestFixture
        }

        let sessionDir = try RecordingStore.createSessionDirectory()
        self.sessionDir = sessionDir
        self.lastSessionDir = nil
        self.audioLevel = 0
        self.audioSpectrumLevels = Array(repeating: 0, count: Self.spectrumBucketCount)
        self.audioLevelHistory = Array(repeating: 0, count: Self.spectrumBucketCount)
        self.lastLevelPublish = 0
        self.lastHistoryPublish = 0
        self.state = .recording
        self.elapsedSeconds = 0
        self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func stopUITestRecording() throws -> URL {
        guard let sessionDir else { throw RecorderError.noSessionDir }
        guard let fixturePath = uiTestMode.audioFixturePath, !fixturePath.isEmpty else {
            throw RecorderError.missingUITestFixture
        }

        let destination = RecordingStore.audioFileURL(in: sessionDir)
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: fixtureURL, to: destination)
        self.lastSessionDir = sessionDir
        return sessionDir
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

// MARK: - Audio level extraction

struct AudioMeterFrame: Sendable {
    let peak: Float
    let bands: [Float]
}

enum AudioSpectrumConfiguration {
    static let bucketCount = 40
}

/// Peak amplitude + frequency buckets of a PCM `CMSampleBuffer`,
/// normalised to 0…1. Handles the two formats ScreenCaptureKit +
/// AVCaptureSession actually deliver on current macOS: 32-bit float
/// interleaved (SCStream default) and 16-bit signed integer
/// (AVCaptureSession microphones).
enum AudioLevelExtractor {
    /// Test-only hook so spectrum bucket tuning can be validated with
    /// deterministic synthetic signals.
    static func analyzeSamplesForTesting(
        _ samples: [Float],
        sampleRate: Double,
        bucketCount: Int = AudioSpectrumConfiguration.bucketCount
    ) -> [Float] {
        analyze(samples: samples, sampleRate: sampleRate, bucketCount: bucketCount).bands
    }

    static func meterFrame(
        _ sampleBuffer: CMSampleBuffer,
        bucketCount: Int = AudioSpectrumConfiguration.bucketCount
    ) -> AudioMeterFrame {
        guard
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
            let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else {
            return AudioMeterFrame(peak: 0, bands: Array(repeating: 0, count: bucketCount))
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let raw = dataPointer else {
            return AudioMeterFrame(peak: 0, bands: Array(repeating: 0, count: bucketCount))
        }

        let asbd = asbdPtr.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let channels = max(Int(asbd.mChannelsPerFrame), 1)

        if isFloat, asbd.mBitsPerChannel == 32 {
            let count = totalLength / MemoryLayout<Float>.size
            return raw.withMemoryRebound(to: Float.self, capacity: count) { ptr in
                let mono = collapseToMono(frameCount: count / channels, channels: channels) { frame, channel in
                    ptr[(frame * channels) + channel]
                }
                return analyze(samples: mono, sampleRate: Double(asbd.mSampleRate), bucketCount: bucketCount)
            }
        }

        if asbd.mBitsPerChannel == 16 {
            let count = totalLength / MemoryLayout<Int16>.size
            return raw.withMemoryRebound(to: Int16.self, capacity: count) { ptr in
                let mono = collapseToMono(frameCount: count / channels, channels: channels) { frame, channel in
                    Float(ptr[(frame * channels) + channel]) / 32768
                }
                return analyze(samples: mono, sampleRate: Double(asbd.mSampleRate), bucketCount: bucketCount)
            }
        }

        return AudioMeterFrame(peak: 0, bands: Array(repeating: 0, count: bucketCount))
    }

    private static func collapseToMono(
        frameCount: Int,
        channels: Int,
        sampleAt: (_ frame: Int, _ channel: Int) -> Float
    ) -> [Float] {
        guard frameCount > 0 else { return [] }
        return (0..<frameCount).map { frame in
            var sum: Float = 0
            for channel in 0..<channels {
                sum += sampleAt(frame, channel)
            }
            return sum / Float(channels)
        }
    }

    private static func analyze(samples: [Float], sampleRate: Double, bucketCount: Int) -> AudioMeterFrame {
        guard !samples.isEmpty else {
            return AudioMeterFrame(peak: 0, bands: Array(repeating: 0, count: bucketCount))
        }

        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }

        let fftSize = 2048
        guard samples.count >= 32 else {
            let clampedPeak = min(peak, 1)
            return AudioMeterFrame(peak: clampedPeak, bands: Array(repeating: clampedPeak, count: bucketCount))
        }

        let truncated = Array(samples.suffix(fftSize))
        let paddedSamples = truncated + Array(repeating: 0, count: max(0, fftSize - truncated.count))

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        let windowed = zip(paddedSamples, window).map(*)

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return AudioMeterFrame(peak: min(peak, 1), bands: Array(repeating: 0, count: bucketCount))
        }

        var inReal = windowed
        var inImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        inReal.withUnsafeMutableBufferPointer { inRealPtr in
            inImag.withUnsafeMutableBufferPointer { inImagPtr in
                outReal.withUnsafeMutableBufferPointer { outRealPtr in
                    outImag.withUnsafeMutableBufferPointer { outImagPtr in
                        let input = DSPSplitComplex(realp: inRealPtr.baseAddress!, imagp: inImagPtr.baseAddress!)
                        var output = DSPSplitComplex(realp: outRealPtr.baseAddress!, imagp: outImagPtr.baseAddress!)
                        fft.forward(input: input, output: &output)
                    }
                }
            }
        }

        let halfCount = fftSize / 2
        let nyquist = sampleRate / 2
        let minFrequency = max(90.0, sampleRate / Double(fftSize))
        // This view is a compact "player-style" spectrum, not a lab-grade
        // analyzer. Cap the displayed range so typical music / speech spreads
        // across the whole width instead of leaving the right edge empty.
        let maxFrequency = max(min(nyquist, 8_000), minFrequency * 2)
        let minLogFrequency = log(minFrequency)
        let maxLogFrequency = log(maxFrequency)

        var bandMagnitudes = [Float](repeating: 0, count: bucketCount)

        for bucketIndex in 0..<bucketCount {
            let startT = Double(bucketIndex) / Double(bucketCount)
            let endT = Double(bucketIndex + 1) / Double(bucketCount)
            let lower = exp(minLogFrequency + ((maxLogFrequency - minLogFrequency) * startT))
            let upper = exp(minLogFrequency + ((maxLogFrequency - minLogFrequency) * endT))
            let center = sqrt(lower * upper)

            var strongest: Float = 0
            var energySum: Float = 0
            var count: Int = 0

            for bin in 1..<halfCount {
                let frequency = (Double(bin) * sampleRate) / Double(fftSize)
                guard frequency >= lower, frequency < upper else { continue }
                let magnitude = hypot(outReal[bin], outImag[bin])
                strongest = max(strongest, magnitude)
                energySum += magnitude * magnitude
                count += 1
            }

            let rms = count > 0 ? sqrt(energySum / Float(count)) : 0
            let bucketEnergy = (rms * 0.78) + (strongest * 0.22)
            // Counterbalance the natural low-frequency bias of music / voice
            // so the compact visualizer behaves more like a traditional player.
            let spectralTiltCompensation = Float(pow(max(center, 140) / 140, 0.42))
            bandMagnitudes[bucketIndex] = bucketEnergy * spectralTiltCompensation
        }

        let smoothedBands = bandMagnitudes.indices.map { index -> Float in
            let previous = bandMagnitudes[max(index - 1, 0)]
            let current = bandMagnitudes[index]
            let next = bandMagnitudes[min(index + 1, bandMagnitudes.count - 1)]
            return (previous * 0.2) + (current * 0.6) + (next * 0.2)
        }

        let maxBand = max(smoothedBands.max() ?? 0, 0.0001)
        let amplitudeScale = min(1, sqrt(min(peak, 1)) * 1.55)
        let normalizedBands = smoothedBands.enumerated().map { index, magnitude in
            let t = Float(index) / Float(max(bucketCount - 1, 1))
            let floorRatio: Float = 0.005   // ~ -46 dB floor
            let clamped = max(magnitude, maxBand * floorRatio)
            let decibels = 20 * log10(clamped / maxBand)
            let dbNormalized = max(0, min(1, (decibels + 46) / 46))
            let equalized = pow(dbNormalized, 0.88) * (0.78 + (0.92 * pow(t, 0.9)))
            return min(1, equalized * amplitudeScale)
        }

        return AudioMeterFrame(peak: min(peak, 1), bands: normalizedBands)
    }
}

// MARK: - System audio receiver

final class SystemAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var isWriterStarted = false

    /// Called on the capture queue for each buffer with a peak + spectrum
    /// snapshot. AudioRecorder hops this to the main actor + throttles to
    /// ~30 Hz for the waveform view.
    var onMeterFrame: ((AudioMeterFrame) -> Void)?

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

        onMeterFrame?(AudioLevelExtractor.meterFrame(sampleBuffer, bucketCount: AudioSpectrumConfiguration.bucketCount))
    }
}

// MARK: - Microphone receiver

final class MicAudioOutput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var isWriterStarted = false

    var onMeterFrame: ((AudioMeterFrame) -> Void)?

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

        onMeterFrame?(AudioLevelExtractor.meterFrame(sampleBuffer, bucketCount: AudioSpectrumConfiguration.bucketCount))
    }
}

// MARK: - Errors

enum RecorderError: LocalizedError {
    case noDisplay
    case noMicrophone
    case micDenied
    case screenCaptureDenied
    case micSetupFailed
    case notRecording
    case noSessionDir
    case exportFailed
    case missingUITestFixture

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found for audio capture"
        case .noMicrophone: return "No microphone found"
        case .micDenied: return "Microphone access denied. Enable in System Settings > Privacy & Security > Microphone"
        case .screenCaptureDenied: return "Screen & system audio recording access is required. Enable Recappi Mini in System Settings > Privacy & Security > Screen & System Audio Recording"
        case .micSetupFailed: return "Couldn't set up microphone capture"
        case .notRecording: return "Not currently recording"
        case .noSessionDir: return "No session directory"
        case .exportFailed: return "Failed to merge audio sources"
        case .missingUITestFixture: return "UI test fixture audio is missing"
        }
    }
}
