import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

public struct CaptureAudioRecordingSessionConfiguration: Sendable, Equatable {
    public var sessionID: String
    public var sessionDirectoryURL: URL
    public var includeSystemAudio: Bool
    public var targetBundleID: String?
    public var includeMicrophone: Bool
    public var microphoneDeviceID: String?
    public var metadata: CaptureSessionMetadata

    public init(
        sessionID: String,
        sessionDirectoryURL: URL,
        includeSystemAudio: Bool,
        targetBundleID: String? = nil,
        includeMicrophone: Bool,
        microphoneDeviceID: String? = nil,
        metadata: CaptureSessionMetadata
    ) {
        self.sessionID = sessionID
        self.sessionDirectoryURL = sessionDirectoryURL
        self.includeSystemAudio = includeSystemAudio
        self.targetBundleID = targetBundleID
        self.includeMicrophone = includeMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.metadata = metadata
    }

    public var effectiveSelection: CaptureSelection {
        CaptureSelection(
            sourceID: targetBundleID.map { "app:\($0)" } ?? "system",
            includeMicrophone: includeMicrophone,
            microphoneDeviceID: microphoneDeviceID
        )
    }
}

public enum CaptureAudioRecordingSessionError: Error, Equatable, LocalizedError {
    case noAudioInputs
    case noDisplay
    case targetApplicationUnavailable
    case noMicrophone
    case microphoneUnavailable
    case microphoneSetupFailed
    case notRecording
    case pauseUnsupported

    public var errorDescription: String? {
        switch self {
        case .noAudioInputs:
            return "No audio inputs were selected"
        case .noDisplay:
            return "No display is available for ScreenCaptureKit audio"
        case .targetApplicationUnavailable:
            return "The selected application is unavailable"
        case .noMicrophone:
            return "No microphone is available"
        case .microphoneUnavailable:
            return "The selected microphone is unavailable"
        case .microphoneSetupFailed:
            return "Couldn't configure microphone capture"
        case .notRecording:
            return "The capture session is not recording"
        case .pauseUnsupported:
            return "Audio recording pause is not supported yet"
        }
    }
}

public final class CaptureAudioRecordingSession: CaptureSession, @unchecked Sendable {
    public let states: AsyncStream<CaptureState>
    public let levels: AsyncStream<CaptureLevel>

    private let stateContinuation: AsyncStream<CaptureState>.Continuation
    private let levelContinuation: AsyncStream<CaptureLevel>.Continuation
    private let configuration: CaptureAudioRecordingSessionConfiguration
    private let systemQueue: DispatchQueue
    private let microphoneQueue: DispatchQueue
    private let uptime: () -> TimeInterval

    private var status: CaptureState.Status = .idle
    private var startedAtUptime: TimeInterval?
    private var stream: SCStream?
    private var streamOutput: CaptureScreenCaptureKitAudioOutput?
    private var systemOutput: CaptureAudioSampleBufferOutput?
    private var microphoneCapture: CaptureMicrophoneAudioCapture?
    private var microphoneOutput: CaptureAudioSampleBufferOutput?

    public init(
        configuration: CaptureAudioRecordingSessionConfiguration,
        systemQueue: DispatchQueue = DispatchQueue(label: "RecappiCaptureCore.SystemAudio"),
        microphoneQueue: DispatchQueue = DispatchQueue(label: "RecappiCaptureCore.Microphone"),
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.configuration = configuration
        self.systemQueue = systemQueue
        self.microphoneQueue = microphoneQueue
        self.uptime = uptime

        var stateContinuation: AsyncStream<CaptureState>.Continuation!
        states = AsyncStream(bufferingPolicy: .bufferingNewest(20)) { continuation in
            stateContinuation = continuation
        }
        self.stateContinuation = stateContinuation

        var levelContinuation: AsyncStream<CaptureLevel>.Continuation!
        levels = AsyncStream(bufferingPolicy: .bufferingNewest(40)) { continuation in
            levelContinuation = continuation
        }
        self.levelContinuation = levelContinuation
    }

    deinit {
        stateContinuation.finish()
        levelContinuation.finish()
    }

    public func start() async throws {
        guard status == .idle else { return }
        guard configuration.includeSystemAudio || configuration.includeMicrophone else {
            throw CaptureAudioRecordingSessionError.noAudioInputs
        }

        startedAtUptime = uptime()
        transition(to: .starting)

        do {
            try FileManager.default.createDirectory(
                at: configuration.sessionDirectoryURL,
                withIntermediateDirectories: true
            )

            if configuration.includeSystemAudio {
                try await startSystemAudio()
            }
            if configuration.includeMicrophone {
                try await startMicrophone()
            }

            transition(to: .recording)
        } catch {
            transition(to: .failed, message: error.localizedDescription)
            await cleanupCaptureResources()
            finishEventStreams()
            throw error
        }
    }

    public func pause() async throws {
        throw CaptureAudioRecordingSessionError.pauseUnsupported
    }

    public func resume() async throws {
        throw CaptureAudioRecordingSessionError.pauseUnsupported
    }

    public func stop() async throws -> CaptureArtifact {
        guard status == .recording else {
            throw CaptureAudioRecordingSessionError.notRecording
        }
        transition(to: .stopping)

        let resources = detachCaptureResources()

        resources.microphoneCapture?.stop()
        var stopCaptureError: Error?
        do {
            try await resources.stream?.stopCapture()
        } catch {
            stopCaptureError = error
        }

        do {
            transition(to: .finalizing)
            let (systemURL, microphoneURL) = try await finishOutputs(
                systemOutput: resources.systemOutput,
                microphoneOutput: resources.microphoneOutput
            )
            let sourceURLs = [systemURL, microphoneURL].compactMap { $0 }

            if let stopCaptureError {
                throw stopCaptureError
            }
            guard !sourceURLs.isEmpty else {
                throw CaptureAudioError.noCapturedAudio
            }

            let mixedURL = configuration.sessionDirectoryURL.appendingPathComponent("recording.m4a")
            try await CaptureAudioMixer.mix(sources: sourceURLs, to: mixedURL)
            try? CaptureAudioDiagnostics.write(
                sources: sourceURLs,
                output: mixedURL,
                to: configuration.sessionDirectoryURL
            )

            transition(to: .completed)
            finishEventStreams()
            return CaptureArtifact(
                sessionDirectoryURL: configuration.sessionDirectoryURL,
                mixedAudioURL: mixedURL,
                systemAudioURL: systemURL,
                microphoneAudioURL: microphoneURL,
                effectiveSelection: configuration.effectiveSelection
            )
        } catch {
            transition(to: .failed, message: error.localizedDescription)
            finishEventStreams()
            throw error
        }
    }

    public func cancel() async {
        guard status != .cancelled, status != .completed, status != .failed else { return }
        transition(to: .cancelled)
        await cleanupCaptureResources()
        finishEventStreams()
    }

    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureAudioRecordingSessionError.noDisplay
        }

        let writer = CaptureSegmentedAudioWriter(
            finalURL: configuration.sessionDirectoryURL.appendingPathComponent("system.caf"),
            processingQueue: systemQueue
        )
        let output = CaptureAudioSampleBufferOutput(
            writer: writer,
            input: .system,
            startedAtUptime: startedAtUptime ?? uptime()
        ) { [weak self] level in
            self?.levelContinuation.yield(level)
        }
        let streamOutput = CaptureScreenCaptureKitAudioOutput(output: output)
        let capture = try CaptureScreenCaptureKitAudio.makeStream(
            display: display,
            applications: content.applications,
            targetBundleID: configuration.targetBundleID,
            output: streamOutput,
            sampleHandlerQueue: systemQueue
        )
        self.systemOutput = output
        self.streamOutput = streamOutput
        self.stream = capture.stream
        if configuration.targetBundleID != nil, capture.matchedBundleID == nil {
            throw CaptureAudioRecordingSessionError.targetApplicationUnavailable
        }
        try await capture.stream.startCapture()
    }

    private func startMicrophone() async throws {
        let writer = CaptureSegmentedAudioWriter(
            finalURL: configuration.sessionDirectoryURL.appendingPathComponent("mic.caf"),
            processingQueue: microphoneQueue
        )
        let output = CaptureAudioSampleBufferOutput(
            writer: writer,
            input: .microphone,
            startedAtUptime: startedAtUptime ?? uptime()
        ) { [weak self] level in
            self?.levelContinuation.yield(level)
        }
        let capture = CaptureMicrophoneAudioCapture(
            output: output,
            queue: microphoneQueue,
            deviceID: configuration.microphoneDeviceID
        )
        try await capture.start()
        microphoneOutput = output
        microphoneCapture = capture
    }

    private func transition(to status: CaptureState.Status, message: String? = nil) {
        self.status = status
        let startedAtUptime = startedAtUptime ?? uptime()
        let atMs = Int64(max(0, (uptime() - startedAtUptime) * 1_000).rounded())
        stateContinuation.yield(CaptureState(
            sessionID: configuration.sessionID,
            status: status,
            message: message,
            atMs: atMs
        ))
    }

    private func detachCaptureResources() -> (
        stream: SCStream?,
        systemOutput: CaptureAudioSampleBufferOutput?,
        microphoneCapture: CaptureMicrophoneAudioCapture?,
        microphoneOutput: CaptureAudioSampleBufferOutput?
    ) {
        let resources = (
            stream: stream,
            systemOutput: systemOutput,
            microphoneCapture: microphoneCapture,
            microphoneOutput: microphoneOutput
        )
        stream = nil
        streamOutput = nil
        systemOutput = nil
        microphoneCapture = nil
        microphoneOutput = nil
        return resources
    }

    private func cleanupCaptureResources() async {
        let resources = detachCaptureResources()
        resources.microphoneCapture?.stop()
        try? await resources.stream?.stopCapture()
        _ = try? await resources.systemOutput?.finishWriting()
        _ = try? await resources.microphoneOutput?.finishWriting()
    }

    private func finishOutputs(
        systemOutput: CaptureAudioSampleBufferOutput?,
        microphoneOutput: CaptureAudioSampleBufferOutput?
    ) async throws -> (systemURL: URL?, microphoneURL: URL?) {
        var firstError: Error?
        var systemURL: URL?
        var microphoneURL: URL?

        do {
            systemURL = try await systemOutput?.finishWriting()
        } catch {
            firstError = error
        }

        do {
            microphoneURL = try await microphoneOutput?.finishWriting()
        } catch {
            firstError = firstError ?? error
        }

        if let firstError {
            throw firstError
        }
        return (systemURL, microphoneURL)
    }

    private func finishEventStreams() {
        stateContinuation.finish()
        levelContinuation.finish()
    }
}

private final class CaptureScreenCaptureKitAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let output: CaptureAudioSampleBufferOutput

    init(output: CaptureAudioSampleBufferOutput) {
        self.output = output
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        output.append(sampleBuffer)
    }
}

private final class CaptureMicrophoneAudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let output: CaptureAudioSampleBufferOutput
    private let queue: DispatchQueue
    private let deviceID: String?
    private var session: AVCaptureSession?

    init(output: CaptureAudioSampleBufferOutput, queue: DispatchQueue, deviceID: String?) {
        self.output = output
        self.queue = queue
        self.deviceID = deviceID
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let device = Self.resolveDevice(id: self.deviceID) else {
                        throw self.deviceID == nil
                            ? CaptureAudioRecordingSessionError.noMicrophone
                            : CaptureAudioRecordingSessionError.microphoneUnavailable
                    }
                    let captureSession = AVCaptureSession()
                    let input = try AVCaptureDeviceInput(device: device)
                    guard captureSession.canAddInput(input) else {
                        throw CaptureAudioRecordingSessionError.microphoneSetupFailed
                    }
                    captureSession.addInput(input)

                    let output = AVCaptureAudioDataOutput()
                    output.audioSettings = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsNonInterleaved: false,
                    ]
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    guard captureSession.canAddOutput(output) else {
                        throw CaptureAudioRecordingSessionError.microphoneSetupFailed
                    }
                    captureSession.addOutput(output)
                    captureSession.startRunning()
                    self.session = captureSession
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        session?.stopRunning()
        session = nil
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        self.output.append(sampleBuffer)
    }

    private static func resolveDevice(id: String?) -> AVCaptureDevice? {
        if let id {
            return AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            ).devices.first { $0.uniqueID == id }
        }
        return AVCaptureDevice.default(for: .audio)
    }
}
