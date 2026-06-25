import Accelerate
import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation

private let protocolVersion = 1
private let sidecarName = "recappi-mini-sidecar"
private let sidecarVersion = ProcessInfo.processInfo.environment["RECAPPI_SIDECAR_VERSION"] ?? "0.1.0"

@main
struct RecappiMiniSidecarMain {
    static func main() async {
        let sidecar = RecappiMiniSidecar()
        sidecar.readyEvent()

        while let line = readLine() {
            await sidecar.handle(line)
        }
    }
}

private final class RecappiMiniSidecar {
    private var activeSession: SidecarRecordingSession?

    func handle(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any]
        else {
            return
        }

        let id = requestID(from: object)
        do {
            switch method(from: object) {
            case "recappi.handshake":
                result(id: id, [
                    "protocolVersion": protocolVersion,
                    "sidecar": sidecarInfo(),
                    "capabilities": ["recording.capture"],
                ])
            case "recappi.recording.sources.list":
                result(id: id, [
                    "sources": RecordingInputCatalog.sources(),
                ])
            case "recappi.recording.microphones.list":
                result(id: id, [
                    "microphones": RecordingInputCatalog.microphones(),
                ])
            case "recappi.permissions.status":
                let params = object["params"] as? [String: Any] ?? [:]
                let options = RecordingOptions(params["options"] as? [String: Any] ?? [:])
                result(id: id, [
                    "permissions": PermissionPreflight.status(options: options),
                ])
            case "recappi.recording.status":
                let params = object["params"] as? [String: Any]
                let sessionId = params?["sessionId"] as? String ?? "none"
                let state = activeSession?.id == sessionId ? activeSession?.state.rawValue ?? "idle" : "idle"
                result(id: id, [
                    "sessionId": sessionId,
                    "state": state,
                    "localSessionRef": activeSession?.localSessionRef as Any,
                ].compactJSON())
            case "recappi.recording.start":
                guard activeSession == nil else {
                    throw SidecarFailure(code: -32030, message: "A Recappi CLI recording is already running.")
                }
                let params = object["params"] as? [String: Any] ?? [:]
                let options = RecordingOptions(params["options"] as? [String: Any] ?? [:])
                let account = params["account"] as? [String: Any] ?? [:]
                let session = try await SidecarRecordingSession(options: options, account: account)
                try await session.start()
                activeSession = session
                emitRecordingState(session)
                var startResult: [String: Any] = [
                    "sessionId": session.id,
                    "state": session.state.rawValue,
                ]
                if let localSessionRef = session.localSessionRef {
                    startResult["localSessionRef"] = localSessionRef
                }
                result(id: id, startResult)
            case "recappi.recording.stop":
                let params = object["params"] as? [String: Any]
                let sessionId = params?["sessionId"] as? String ?? ""
                guard let session = activeSession, session.id == sessionId else {
                    throw SidecarFailure(code: -32031, message: "No active Recappi CLI recording matches this session.")
                }
                emitRecordingState(session, override: .stopping)
                let stopped = try await session.stop()
                activeSession = nil
                emitLocalArtifact(stopped.artifact)
                emitRecordingState(session, override: .completed, artifact: stopped.artifact)
                var stopResult: [String: Any] = [
                    "sessionId": session.id,
                    "state": RecordingState.completed.rawValue,
                    "artifacts": [stopped.artifact.json],
                ]
                if let localSessionRef = session.localSessionRef {
                    stopResult["localSessionRef"] = localSessionRef
                }
                result(id: id, stopResult)
            case "recappi.recording.cancel":
                let params = object["params"] as? [String: Any]
                let sessionId = params?["sessionId"] as? String ?? ""
                if let session = activeSession, session.id == sessionId {
                    await session.cancel()
                    activeSession = nil
                }
                result(id: id, [
                    "sessionId": sessionId.isEmpty ? "none" : sessionId,
                    "state": RecordingState.cancelled.rawValue,
                ])
            default:
                throw SidecarFailure(
                    code: -32601,
                    message: "Unknown Recappi sidecar method.",
                    data: ["method": method(from: object) ?? ""]
                )
            }
        } catch let failure as SidecarFailure {
            error(id: id, code: failure.code, message: failure.message, data: failure.data)
        } catch {
            let failure = SidecarFailure.recording(error)
            self.error(id: id, code: failure.code, message: failure.message, data: failure.data)
        }
    }

    func readyEvent() {
        writeJSON([
            "jsonrpc": "2.0",
            "method": "recappi.event",
            "params": [
                "type": "ready",
                "protocolVersion": protocolVersion,
                "sidecar": sidecarInfo(),
            ],
        ])
    }

    private func sidecarInfo() -> [String: Any] {
        [
            "name": sidecarName,
            "version": sidecarVersion,
        ]
    }

    private func emitRecordingState(
        _ session: SidecarRecordingSession,
        override: RecordingState? = nil,
        artifact: LocalArtifact? = nil
    ) {
        var params: [String: Any] = [
            "type": "recording.state",
            "sessionId": session.id,
            "state": (override ?? session.state).rawValue,
        ]
        if let localSessionRef = session.localSessionRef {
            params["localSessionRef"] = localSessionRef
        }
        if let artifact {
            params["artifacts"] = [artifact.json]
        }
        writeJSON([
            "jsonrpc": "2.0",
            "method": "recappi.event",
            "params": params,
        ])
    }

    private func emitLocalArtifact(_ artifact: LocalArtifact) {
        writeJSON([
            "jsonrpc": "2.0",
            "method": "recappi.event",
            "params": [
                "type": "local_artifact.upserted",
                "artifact": artifact.json,
            ],
        ])
    }

    @discardableResult
    private func writeJSON(_ value: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let line = String(data: data, encoding: .utf8)
        else {
            return false
        }
        print(line)
        fflush(stdout)
        return true
    }

    private func result(id: Any, _ value: [String: Any]) {
        writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "result": value,
        ])
    }

    private func error(id: Any, code: Int, message: String, data: [String: String]? = nil) {
        var payload: [String: Any] = [
            "code": code,
            "message": message,
        ]
        if let data {
            payload["data"] = data
        }
        writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "error": payload,
        ])
    }

    private func requestID(from object: [String: Any]) -> Any {
        object["id"] ?? NSNull()
    }

    private func method(from object: [String: Any]) -> String? {
        object["method"] as? String
    }
}

private struct RecordingOptions {
    let includeSystemAudio: Bool
    let includeMicrophone: Bool
    let targetBundleId: String?
    let microphoneDeviceId: String?
    let liveCaptions: Bool
    let title: String?

    init(_ raw: [String: Any]) {
        includeSystemAudio = raw["includeSystemAudio"] as? Bool ?? true
        includeMicrophone = raw["includeMicrophone"] as? Bool ?? true
        targetBundleId = raw["targetBundleId"] as? String
        microphoneDeviceId = raw["microphoneDeviceId"] as? String
        liveCaptions = raw["liveCaptions"] as? Bool ?? false
        title = raw["title"] as? String
    }
}

private enum RecordingInputCatalog {
    static func sources() -> [[String: Any]] {
        var output: [[String: Any]] = [
            [
                "id": "system",
                "kind": "system",
                "label": "System audio · all apps",
            ],
        ]
        var seen = Set<String>()
        let apps = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular && app.isTerminated == false && app.bundleIdentifier != nil
            }
            .sorted { lhs, rhs in
                (lhs.localizedName ?? lhs.bundleIdentifier ?? "") < (rhs.localizedName ?? rhs.bundleIdentifier ?? "")
            }

        for app in apps {
            guard let bundleId = app.bundleIdentifier,
                  seen.insert(bundleId).inserted,
                  CoreAudioProcessResolver.processObjectID(pid: app.processIdentifier) != nil
            else { continue }
            let appName = app.localizedName ?? bundleId
            output.append([
                "id": "app:\(bundleId)",
                "kind": "app",
                "label": appName,
                "appName": appName,
                "bundleId": bundleId,
            ])
        }
        return output
    }

    static func microphones() -> [[String: Any]] {
        let defaultId = AVCaptureDevice.default(for: .audio)?.uniqueID
        let devices = microphoneDevices()
        return devices
            .sorted { lhs, rhs in
                if lhs.uniqueID == defaultId { return true }
                if rhs.uniqueID == defaultId { return false }
                return lhs.localizedName < rhs.localizedName
            }
            .map { device in
                [
                    "id": device.uniqueID,
                    "label": device.localizedName,
                    "isDefault": device.uniqueID == defaultId,
                ]
            }
    }

    static func microphoneDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }
}

private enum RecordingState: String {
    case idle
    case starting
    case recording
    case stopping
    case finalizing
    case completed
    case failed
    case cancelled
}

private struct LocalArtifact {
    let sessionDir: URL
    let audioURL: URL
    let options: RecordingOptions

    var json: [String: Any] {
        var metadata: [String: Any] = [
            "audioPath": audioURL.path,
            "includeSystemAudio": options.includeSystemAudio,
            "includeMicrophone": options.includeMicrophone,
            "source": "recappi-cli-sidecar",
        ]
        if let targetBundleId = options.targetBundleId {
            metadata["targetBundleId"] = targetBundleId
        }
        if let microphoneDeviceId = options.microphoneDeviceId {
            metadata["microphoneDeviceId"] = microphoneDeviceId
        }
        return [
            "kind": "recording_session",
            "localPath": sessionDir.path,
            "metadata": metadata,
        ]
    }
}

private struct StoppedRecording {
    let artifact: LocalArtifact
}

private final class SidecarRecordingSession {
    let id = UUID().uuidString
    let options: RecordingOptions
    let account: [String: Any]
    private(set) var state: RecordingState = .idle
    private(set) var sessionDir: URL?
    private var systemCapture: SystemAudioCapture?
    private var microphoneCapture: MicrophoneCapture?
    private let systemQueue = DispatchQueue(label: "RecappiMiniSidecar.SystemAudio")
    private let microphoneQueue = DispatchQueue(label: "RecappiMiniSidecar.Microphone")

    init(options: RecordingOptions, account: [String: Any]) async throws {
        guard options.includeSystemAudio || options.includeMicrophone else {
            throw SidecarFailure(
                code: -32021,
                message: "Choose at least one audio source before starting a recording.",
                data: ["cliCode": "usage.invalid_argument"]
            )
        }
        self.options = options
        self.account = account
    }

    var localSessionRef: String? {
        sessionDir?.path
    }

    func start() async throws {
        state = .starting
        try await PermissionPreflight.require(options: options)
        let dir = try Self.createSessionDirectory()
        sessionDir = dir
        try writeSessionMetadata(to: dir)

        if options.includeSystemAudio {
            let writer = SegmentedAudioWriter(
                finalURL: dir.appendingPathComponent("system.caf"),
                processingQueue: systemQueue
            )
            let output = SampleBufferAudioOutput(writer: writer)
            let capture = SystemAudioCapture(
                output: output,
                captureQueue: systemQueue,
                targetBundleId: options.targetBundleId
            )
            try await Task.detached(priority: .userInitiated) {
                try capture.start()
            }.value
            systemCapture = capture
        }

        if options.includeMicrophone {
            let writer = SegmentedAudioWriter(
                finalURL: dir.appendingPathComponent("mic.caf"),
                processingQueue: microphoneQueue
            )
            let capture = MicrophoneCapture(
                writer: writer,
                queue: microphoneQueue,
                deviceId: options.microphoneDeviceId
            )
            try await capture.start()
            microphoneCapture = capture
        }

        state = .recording
    }

    func stop() async throws -> StoppedRecording {
        guard state == .recording else {
            throw SidecarFailure(code: -32032, message: "Recappi CLI recording is not currently running.")
        }
        state = .stopping

        let systemCapture = systemCapture
        let microphoneCapture = microphoneCapture
        self.systemCapture = nil
        self.microphoneCapture = nil

        microphoneCapture?.stop()
        systemCapture?.stop()

        state = .finalizing
        let systemURL = try await systemCapture?.finishWriting()
        let microphoneURL = try await microphoneCapture?.finishWriting()
        let sources = [systemURL, microphoneURL].compactMap { $0 }
        guard !sources.isEmpty else {
            throw SidecarFailure(
                code: -32033,
                message: "No audio was captured. Check macOS permissions and make sure audio is playing before trying again.",
                data: ["cliCode": "record.capture_failed"]
            )
        }
        guard let sessionDir else {
            throw SidecarFailure(code: -32034, message: "Recording session directory is missing.")
        }

        let audioURL = sessionDir.appendingPathComponent("recording.m4a")
        try await AudioMixer.mix(sources: sources, to: audioURL)
        try? writeCaptureDiagnostics(sources: sources, output: audioURL, to: sessionDir)
        state = .completed
        return StoppedRecording(
            artifact: LocalArtifact(sessionDir: sessionDir, audioURL: audioURL, options: options)
        )
    }

    func cancel() async {
        state = .cancelled
        microphoneCapture?.stop()
        systemCapture?.stop()
        _ = try? await microphoneCapture?.finishWriting()
        _ = try? await systemCapture?.finishWriting()
        if let sessionDir {
            try? FileManager.default.removeItem(at: sessionDir)
        }
        microphoneCapture = nil
        systemCapture = nil
        sessionDir = nil
    }

    private func writeSessionMetadata(to dir: URL) throws {
        var metadata: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "source": "recappi-cli-sidecar",
            "sessionId": id,
            "includeSystemAudio": options.includeSystemAudio,
            "includeMicrophone": options.includeMicrophone,
            "liveCaptions": options.liveCaptions,
        ]
        if let targetBundleId = options.targetBundleId {
            metadata["targetBundleId"] = targetBundleId
        }
        if let microphoneDeviceId = options.microphoneDeviceId {
            metadata["microphoneDeviceId"] = microphoneDeviceId
        }
        if let title = options.title {
            metadata["title"] = title
        }
        if let userId = account["userId"] as? String {
            metadata["accountUserId"] = userId
        }
        if let origin = account["backendOrigin"] as? String {
            metadata["accountBackendOrigin"] = origin
        }
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("session-metadata.json"))
    }

    private func writeCaptureDiagnostics(sources: [URL], output: URL, to dir: URL) throws {
        let payload: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "sources": sources.map(Self.fileInfo),
            "output": Self.fileInfo(output),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("audio-capture.json"))
    }

    private static func fileInfo(_ url: URL) -> [String: Any] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return [
            "fileName": url.lastPathComponent,
            "path": url.path,
            "exists": FileManager.default.fileExists(atPath: url.path),
            "byteCount": attrs?[.size] as? Int64 as Any,
        ].compactJSON()
    }

    private static func createSessionDirectory() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let base = docs.appendingPathComponent("Recappi Mini", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "\(formatter.string(from: Date()))-cli-\(UUID().uuidString.prefix(8))"
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private enum PermissionPreflight {
    static func status(options: RecordingOptions) -> [[String: String]] {
        var permissions: [[String: String]] = []
        if options.includeSystemAudio {
            let granted = CGPreflightScreenCaptureAccess()
            permissions.append([
                "name": "screen_recording",
                "status": granted ? "granted" : "unknown",
                "hint": "Open System Settings > Privacy & Security > Screen & System Audio Recording, allow Recappi Mini Sidecar or your terminal, then retry recappi record.",
            ])
        }
        if options.includeMicrophone {
            permissions.append([
                "name": "microphone",
                "status": microphoneStatus(),
                "hint": "Open System Settings > Privacy & Security > Microphone, allow Recappi Mini Sidecar or your terminal, then retry recappi record.",
            ])
        }
        return permissions
    }

    static func require(options: RecordingOptions) async throws {
        if options.includeMicrophone {
            try await requireMicrophone()
        }
        if options.includeSystemAudio {
            try requireScreenCapture()
        }
    }

    private static func requireMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            if allowed { return }
            throw microphoneDenied()
        case .denied, .restricted:
            throw microphoneDenied()
        @unknown default:
            throw microphoneDenied()
        }
    }

    private static func requireScreenCapture() throws {
        if CGPreflightScreenCaptureAccess() {
            return
        }
        _ = CGRequestScreenCaptureAccess()
        guard CGPreflightScreenCaptureAccess() else {
            throw SidecarFailure(
                code: -32020,
                message: "Screen & System Audio Recording access is required before the CLI can record system audio.",
                data: [
                    "cliCode": "record.permission_required",
                    "permission": "screen_recording",
                    "recovery": "Open System Settings > Privacy & Security > Screen & System Audio Recording, allow Recappi Mini Sidecar or your terminal, then retry recappi record.",
                ]
            )
        }
    }

    private static func microphoneDenied() -> SidecarFailure {
        SidecarFailure(
            code: -32020,
            message: "Microphone access is required before the CLI can record microphone audio.",
            data: [
                "cliCode": "record.permission_required",
                "permission": "microphone",
                "recovery": "Open System Settings > Privacy & Security > Microphone, allow Recappi Mini Sidecar or your terminal, then retry recappi record.",
            ]
        )
    }

    private static func microphoneStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "granted"
        case .denied, .restricted:
            return "denied"
        case .notDetermined:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }
}

private struct SidecarFailure: Error {
    let code: Int
    let message: String
    let data: [String: String]?

    init(code: Int, message: String, data: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    static func recording(_ error: Error) -> SidecarFailure {
        if let failure = error as? SidecarFailure {
            return failure
        }
        return SidecarFailure(
            code: -32050,
            message: error.localizedDescription,
            data: ["cliCode": "record.capture_failed"]
        )
    }
}

private final class SampleBufferAudioOutput: @unchecked Sendable {
    private let writer: SegmentedAudioWriter

    init(writer: SegmentedAudioWriter) {
        self.writer = writer
    }

    func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid else { return }
        writer.append(sampleBuffer)
    }

    func finishWriting() async throws -> URL? {
        try await writer.finishWriting()
    }
}

private final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let writer: SegmentedAudioWriter
    private let queue: DispatchQueue
    private let deviceId: String?
    private var session: AVCaptureSession?

    init(writer: SegmentedAudioWriter, queue: DispatchQueue, deviceId: String?) {
        self.writer = writer
        self.queue = queue
        self.deviceId = deviceId
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let device = Self.resolveDevice(id: self.deviceId) else {
                        throw SidecarFailure(
                            code: -32040,
                            message: self.deviceId == nil
                                ? "No microphone is available."
                                : "The selected microphone is no longer available.",
                            data: ["cliCode": "record.capture_failed"]
                        )
                    }
                    let captureSession = AVCaptureSession()
                    let input = try AVCaptureDeviceInput(device: device)
                    guard captureSession.canAddInput(input) else {
                        throw SidecarFailure(code: -32041, message: "Could not attach the selected microphone.")
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
                        throw SidecarFailure(code: -32042, message: "Could not attach microphone output.")
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

    func finishWriting() async throws -> URL? {
        try await writer.finishWriting()
    }

    private static func resolveDevice(id: String?) -> AVCaptureDevice? {
        if let id,
           let device = RecordingInputCatalog.microphoneDevices().first(where: { $0.uniqueID == id }) {
            return device
        }
        if id != nil {
            return nil
        }
        return AVCaptureDevice.default(for: .audio)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        writer.append(sampleBuffer)
    }
}

private final class SystemAudioCapture: @unchecked Sendable {
    private let output: SampleBufferAudioOutput
    private let captureQueue: DispatchQueue
    private let targetBundleId: String?
    private let stateQueue = DispatchQueue(label: "RecappiMiniSidecar.SystemAudio.state")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleFactory: CoreAudioTapSampleBufferFactory?
    private var isStarted = false

    init(output: SampleBufferAudioOutput, captureQueue: DispatchQueue, targetBundleId: String?) {
        self.output = output
        self.captureQueue = captureQueue
        self.targetBundleId = targetBundleId
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !isStarted else { return }
        let tapDescription = try makeTapDescription()
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(tapDescription, &newTapID), operation: "AudioHardwareCreateProcessTap")
        tapID = newTapID

        let tapUID = try readTapUID(tapID)
        let tapFormat = try readTapFormat(tapID)
        sampleFactory = try CoreAudioTapSampleBufferFactory(sourceFormat: tapFormat)

        var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Recappi CLI System Audio Tap",
            kAudioAggregateDeviceUIDKey: "com.recappi.mini.cli.system-audio-tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationLowQuality,
                ] as [String: Any],
            ],
        ]
        try check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateDeviceID),
            operation: "AudioHardwareCreateAggregateDevice"
        )
        aggregateDeviceID = newAggregateDeviceID

        var newIOProcID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, captureQueue) { [weak self] _, inputData, inputTime, _, _ in
                self?.handleInput(inputData, inputTime: inputTime)
            },
            operation: "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = newIOProcID

        try check(AudioDeviceStart(aggregateDeviceID, newIOProcID), operation: "AudioDeviceStart")
        isStarted = true
    }

    func stop() {
        stateQueue.sync {
            guard tapID != kAudioObjectUnknown || aggregateDeviceID != kAudioObjectUnknown else { return }

            if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            ioProcID = nil

            if aggregateDeviceID != kAudioObjectUnknown {
                AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            }
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)

            if tapID != kAudioObjectUnknown {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
            sampleFactory = nil
            isStarted = false
        }
    }

    func finishWriting() async throws -> URL? {
        try await output.finishWriting()
    }

    private func makeTapDescription() throws -> CATapDescription {
        let description = CATapDescription()
        description.name = "Recappi CLI System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isMixdown = true
        description.isMono = false

        if let targetBundleId {
            let targets = CoreAudioProcessResolver.processObjectIDs(bundleId: targetBundleId)
            guard !targets.isEmpty else {
                throw SidecarFailure(
                    code: -32043,
                    message: "The selected app is no longer available for recording.",
                    data: ["cliCode": "record.capture_failed"]
                )
            }
            description.processes = targets
            description.isExclusive = false
            return description
        }

        var excluded: [AudioObjectID] = []
        if let selfProcessID = CoreAudioProcessResolver.processObjectID(pid: getpid()) {
            excluded.append(selfProcessID)
        }
        description.processes = excluded
        description.isExclusive = true
        return description
    }

    private func handleInput(
        _ inputData: UnsafePointer<AudioBufferList>?,
        inputTime: UnsafePointer<AudioTimeStamp>?
    ) {
        guard let inputData else { return }
        do {
            guard let sampleBuffer = try sampleFactory?.makeSampleBuffer(
                from: inputData,
                inputTime: inputTime?.pointee
            ) else {
                return
            }
            output.handleAudioSampleBuffer(sampleBuffer)
        } catch {
            // Drop individual malformed buffers; the stop path will fail if no
            // readable source file is produced.
        }
    }

    private func readTapUID(_ tapID: AudioObjectID) throws -> CFString {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var tapUID: Unmanaged<CFString>?
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &tapUID),
            operation: "kAudioTapPropertyUID"
        )
        guard let uid = tapUID?.takeRetainedValue() else {
            throw CoreAudioStatusError(operation: "kAudioTapPropertyUID(empty)", status: -1)
        }
        return uid
    }

    private func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format),
            operation: "kAudioTapPropertyFormat"
        )
        return format
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreAudioStatusError(operation: operation, status: status)
        }
    }
}

private enum CoreAudioProcessResolver {
    static func processObjectIDs(bundleId: String) -> [AudioObjectID] {
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleId && !$0.isTerminated }
            .compactMap { processObjectID(pid: $0.processIdentifier) }
    }

    static func processObjectID(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutablePID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        let status = withUnsafePointer(to: &mutablePID) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                pidPtr,
                &size,
                &processObjectID
            )
        }
        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            return nil
        }
        return processObjectID
    }
}

private struct CoreAudioStatusError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed with OSStatus \(status)"
    }
}

private struct CoreAudioBufferListView {
    private let buffers: [AudioBuffer]

    init(_ audioBufferList: UnsafePointer<AudioBufferList>) {
        let mutableList = UnsafeMutablePointer(mutating: audioBufferList)
        let listPointer = UnsafeMutableAudioBufferListPointer(mutableList)
        buffers = Array(listPointer)
    }

    var isEmpty: Bool { buffers.isEmpty }
    var count: Int { buffers.count }

    subscript(index: Int) -> AudioBuffer {
        buffers[index]
    }
}

private final class CoreAudioTapSampleBufferFactory {
    private let sourceFormat: AudioStreamBasicDescription
    private let outputFormat: AudioStreamBasicDescription
    private let formatDescription: CMAudioFormatDescription
    private var nextFramePosition: Int64 = 0
    private var scratchSamples: [Float] = []

    init(sourceFormat: AudioStreamBasicDescription) throws {
        self.sourceFormat = sourceFormat
        let channelCount = min(max(Int(sourceFormat.mChannelsPerFrame), 1), 2)
        let sampleRate = sourceFormat.mSampleRate.isFinite && sourceFormat.mSampleRate > 0
            ? sourceFormat.mSampleRate
            : 48_000
        var output = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(channelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        outputFormat = output

        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &output,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw CoreAudioStatusError(operation: "CMAudioFormatDescriptionCreate", status: status)
        }
        formatDescription = description
    }

    func makeSampleBuffer(
        from audioBufferList: UnsafePointer<AudioBufferList>,
        inputTime: AudioTimeStamp?
    ) throws -> CMSampleBuffer? {
        if let direct = try directFloat32SampleBuffer(from: audioBufferList, inputTime: inputTime) {
            return direct
        }

        let sampleCount = try fillScratch(from: audioBufferList)
        let channelCount = Int(outputFormat.mChannelsPerFrame)
        guard channelCount > 0, sampleCount > 0 else { return nil }

        let frameCount = sampleCount / channelCount
        guard frameCount > 0 else { return nil }

        let ptsFrame = advancePTS(frameCount: frameCount, inputTime: inputTime)
        let byteCount = sampleCount * MemoryLayout<Float>.stride
        return try scratchSamples.withUnsafeBytes { rawBuffer -> CMSampleBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw CoreAudioStatusError(operation: "scratchSamples empty base", status: -1)
            }
            return try makeCMSampleBuffer(
                bytes: baseAddress,
                byteCount: byteCount,
                frameCount: frameCount,
                ptsFrame: ptsFrame
            )
        }
    }

    private func advancePTS(frameCount: Int, inputTime: AudioTimeStamp?) -> Int64 {
        if let inputTime,
           inputTime.mFlags.contains(.sampleTimeValid),
           inputTime.mSampleTime.isFinite,
           inputTime.mSampleTime >= 0 {
            let ptsFrame = Int64(inputTime.mSampleTime.rounded())
            nextFramePosition = ptsFrame + Int64(frameCount)
            return ptsFrame
        }
        let ptsFrame = nextFramePosition
        nextFramePosition += Int64(frameCount)
        return ptsFrame
    }

    private func directFloat32SampleBuffer(
        from audioBufferList: UnsafePointer<AudioBufferList>,
        inputTime: AudioTimeStamp?
    ) throws -> CMSampleBuffer? {
        let sourceChannels = max(Int(sourceFormat.mChannelsPerFrame), 1)
        let outputChannels = Int(outputFormat.mChannelsPerFrame)
        guard outputChannels > 0, sourceChannels == outputChannels else { return nil }

        let sourceIsFloat = (sourceFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let sourceIsNonInterleaved = (sourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard sourceIsFloat, sourceFormat.mBitsPerChannel == 32, !sourceIsNonInterleaved else { return nil }

        let buffers = CoreAudioBufferListView(audioBufferList)
        guard buffers.count == 1, let data = buffers[0].mData else { return nil }

        let availableSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        let frameCount = availableSamples / sourceChannels
        guard frameCount > 0 else { return nil }

        let ptsFrame = advancePTS(frameCount: frameCount, inputTime: inputTime)
        let byteCount = frameCount * outputChannels * MemoryLayout<Float>.stride
        return try makeCMSampleBuffer(
            bytes: data,
            byteCount: byteCount,
            frameCount: frameCount,
            ptsFrame: ptsFrame
        )
    }

    private func fillScratch(from audioBufferList: UnsafePointer<AudioBufferList>) throws -> Int {
        let buffers = CoreAudioBufferListView(audioBufferList)
        guard !buffers.isEmpty else { return 0 }
        let sourceChannels = max(Int(sourceFormat.mChannelsPerFrame), 1)
        let outputChannels = Int(outputFormat.mChannelsPerFrame)
        let sourceIsFloat = (sourceFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let sourceIsNonInterleaved = (sourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerSample = max(Int(sourceFormat.mBitsPerChannel / 8), 1)

        if sourceIsFloat, sourceFormat.mBitsPerChannel == 32 {
            if sourceIsNonInterleaved || buffers.count > 1 {
                let frameCount = minimumFrameCount(in: buffers, bytesPerSample: MemoryLayout<Float>.size)
                guard frameCount > 0 else { return 0 }
                let total = frameCount * outputChannels
                reserveScratch(total)
                return scratchSamples.withUnsafeMutableBufferPointer { samples -> Int in
                    if let baseAddress = samples.baseAddress {
                        memset(baseAddress, 0, total * MemoryLayout<Float>.size)
                    }
                    for channel in 0..<outputChannels {
                        let bufferIndex = min(channel, buffers.count - 1)
                        guard let data = buffers[bufferIndex].mData else { continue }
                        let ptr = data.assumingMemoryBound(to: Float.self)
                        if outputChannels == 1 {
                            memcpy(samples.baseAddress!, ptr, frameCount * MemoryLayout<Float>.size)
                        } else {
                            for frame in 0..<frameCount {
                                samples[frame * outputChannels + channel] = ptr[frame]
                            }
                        }
                    }
                    return total
                }
            }

            guard let data = buffers[0].mData else { return 0 }
            let availableSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let frames = availableSamples / sourceChannels
            guard frames > 0 else { return 0 }
            let total = frames * outputChannels
            reserveScratch(total)
            let ptr = data.assumingMemoryBound(to: Float.self)
            return scratchSamples.withUnsafeMutableBufferPointer { samples -> Int in
                for frame in 0..<frames {
                    for channel in 0..<outputChannels {
                        samples[frame * outputChannels + channel] = ptr[frame * sourceChannels + min(channel, sourceChannels - 1)]
                    }
                }
                return total
            }
        }

        if sourceFormat.mBitsPerChannel == 16 {
            if sourceIsNonInterleaved || buffers.count > 1 {
                let frameCount = minimumFrameCount(in: buffers, bytesPerSample: MemoryLayout<Int16>.size)
                guard frameCount > 0 else { return 0 }
                let total = frameCount * outputChannels
                reserveScratch(total)
                return scratchSamples.withUnsafeMutableBufferPointer { samples -> Int in
                    if let baseAddress = samples.baseAddress {
                        memset(baseAddress, 0, total * MemoryLayout<Float>.size)
                    }
                    for channel in 0..<outputChannels {
                        let bufferIndex = min(channel, buffers.count - 1)
                        guard let data = buffers[bufferIndex].mData else { continue }
                        let ptr = data.assumingMemoryBound(to: Int16.self)
                        if outputChannels == 1 {
                            convertInt16ToFloat(source: ptr, destination: samples.baseAddress!, count: frameCount)
                        } else {
                            for frame in 0..<frameCount {
                                samples[frame * outputChannels + channel] = Float(ptr[frame]) / 32768.0
                            }
                        }
                    }
                    return total
                }
            }

            guard let data = buffers[0].mData else { return 0 }
            let availableSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Int16>.size
            let frames = availableSamples / sourceChannels
            guard frames > 0 else { return 0 }
            let total = frames * outputChannels
            reserveScratch(total)
            let ptr = data.assumingMemoryBound(to: Int16.self)
            return scratchSamples.withUnsafeMutableBufferPointer { samples -> Int in
                for frame in 0..<frames {
                    for channel in 0..<outputChannels {
                        samples[frame * outputChannels + channel] = Float(ptr[frame * sourceChannels + min(channel, sourceChannels - 1)]) / 32768.0
                    }
                }
                return total
            }
        }

        throw CoreAudioStatusError(operation: "Unsupported tap format bytesPerSample=\(bytesPerSample)", status: -1)
    }

    private func reserveScratch(_ count: Int) {
        if scratchSamples.count < count {
            scratchSamples.append(contentsOf: repeatElement(0, count: count - scratchSamples.count))
        }
    }

    private func convertInt16ToFloat(
        source: UnsafePointer<Int16>,
        destination: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        guard count > 0 else { return }
        vDSP_vflt16(source, 1, destination, 1, vDSP_Length(count))
        var divisor: Float = 32768.0
        vDSP_vsdiv(destination, 1, &divisor, destination, 1, vDSP_Length(count))
    }

    private func minimumFrameCount(in buffers: CoreAudioBufferListView, bytesPerSample: Int) -> Int {
        var result: Int?
        for index in 0..<buffers.count {
            let buffer = buffers[index]
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / bytesPerSample / channelCount
            result = min(result ?? frames, frames)
        }
        return result ?? 0
    }

    private func makeCMSampleBuffer(
        bytes: UnsafeRawPointer,
        byteCount: Int,
        frameCount: Int,
        ptsFrame: Int64
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw CoreAudioStatusError(operation: "CMBlockBufferCreateWithMemoryBlock", status: status)
        }

        status = CMBlockBufferReplaceDataBytes(
            with: bytes,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
        guard status == kCMBlockBufferNoErr else {
            throw CoreAudioStatusError(operation: "CMBlockBufferReplaceDataBytes", status: status)
        }

        let sampleRate = max(Int32(outputFormat.mSampleRate.rounded()), 1)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: ptsFrame, timescale: sampleRate),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw CoreAudioStatusError(operation: "CMSampleBufferCreateReady", status: status)
        }
        return sampleBuffer
    }
}

private struct CaptureStreamFormat: Equatable {
    let sampleRate: Int
    let channelCount: Int

    init(sampleRate: Int, channelCount: Int) {
        self.sampleRate = max(sampleRate, 1)
        self.channelCount = min(max(channelCount, 1), 2)
    }

    init(sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            throw SidecarFailure(code: -32060, message: "Audio format information is unavailable.")
        }

        self.init(
            sampleRate: Int(asbd.pointee.mSampleRate.rounded()),
            channelCount: Int(asbd.pointee.mChannelsPerFrame)
        )
    }

    var recommendedBitRate: Int {
        min(max(channelCount, 1) * 64_000, 256_000)
    }
}

private final class UncheckedAssetWriterRef: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

private final class SegmentedAudioWriter: @unchecked Sendable {
    private let finalURL: URL
    private let processingQueue: DispatchQueue
    private var activeWriter: AVAssetWriter?
    private var activeInput: AVAssetWriterInput?
    private var activeFormat: CaptureStreamFormat?
    private var activeSessionStarted = false
    private var segmentURLs: [URL] = []
    private var segmentIndex = 0
    private var pendingFinalizationCount = 0
    private var pendingError: Error?
    private var finishContinuation: CheckedContinuation<URL?, Error>?

    init(finalURL: URL, processingQueue: DispatchQueue) {
        self.finalURL = finalURL
        self.processingQueue = processingQueue
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard finishContinuation == nil else { return }

        do {
            let streamFormat = try CaptureStreamFormat(sampleBuffer: sampleBuffer)

            if activeFormat != streamFormat || activeWriter == nil || activeInput == nil {
                finishActiveSegment()
                try startSegment(for: sampleBuffer, format: streamFormat)
            }

            guard let writer = activeWriter, let input = activeInput else { return }

            if !activeSessionStarted {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                activeSessionStarted = true
            }

            guard writer.status == .writing else {
                if writer.status == .failed || writer.status == .cancelled {
                    pendingError = pendingError ?? writer.error ?? SidecarFailure(code: -32061, message: "Couldn't append captured audio.")
                }
                return
            }

            guard input.isReadyForMoreMediaData else { return }

            if !input.append(sampleBuffer) {
                pendingError = pendingError ?? writer.error ?? SidecarFailure(code: -32061, message: "Couldn't append captured audio.")
            }
        } catch {
            pendingError = pendingError ?? error
        }
    }

    func finishWriting() async throws -> URL? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            processingQueue.async {
                guard self.finishContinuation == nil else {
                    continuation.resume(throwing: SidecarFailure(code: -32062, message: "Audio finishing is already in progress."))
                    return
                }

                self.finishContinuation = continuation
                self.finishActiveSegment()
                self.completeFinishIfPossible()
            }
        }
    }

    private func startSegment(for sampleBuffer: CMSampleBuffer, format: CaptureStreamFormat) throws {
        let segmentURL = makeSegmentURL(index: segmentIndex)
        segmentIndex += 1

        let fileType = Self.fileType(for: segmentURL)
        let settings = Self.outputSettings(for: format, fileType: fileType)
        let writer = try AVAssetWriter(url: segmentURL, fileType: fileType)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings,
            sourceFormatHint: sampleBuffer.formatDescription
        )
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw SidecarFailure(code: -32063, message: "Couldn't create the audio writer input.")
        }

        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? SidecarFailure(code: -32064, message: "Couldn't start the audio writer.")
        }

        activeWriter = writer
        activeInput = input
        activeFormat = format
        activeSessionStarted = false
        segmentURLs.append(segmentURL)
    }

    private func finishActiveSegment() {
        guard let writer = activeWriter, let input = activeInput else { return }

        activeWriter = nil
        activeInput = nil
        activeFormat = nil
        activeSessionStarted = false

        input.markAsFinished()
        pendingFinalizationCount += 1

        let writerRef = UncheckedAssetWriterRef(writer)
        writer.finishWriting { [weak self, writerRef] in
            guard let self else { return }
            let status = writerRef.writer.status
            let error = writerRef.writer.error

            self.processingQueue.async {
                if status == .failed || status == .cancelled {
                    self.pendingError = self.pendingError ?? error ?? SidecarFailure(code: -32065, message: "Couldn't finalize a captured audio segment.")
                }
                self.pendingFinalizationCount -= 1
                self.completeFinishIfPossible()
            }
        }
    }

    private func completeFinishIfPossible() {
        guard pendingFinalizationCount == 0 else { return }
        guard let continuation = finishContinuation else { return }

        finishContinuation = nil

        if let error = pendingError {
            continuation.resume(throwing: error)
            return
        }

        Task {
            do {
                let finalizedURL = try await finalizeSegments()
                continuation.resume(returning: finalizedURL)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func finalizeSegments() async throws -> URL? {
        guard !segmentURLs.isEmpty else { return nil }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }

        if segmentURLs.count == 1 {
            try fileManager.moveItem(at: segmentURLs[0], to: finalURL)
            return finalURL
        }

        let outputFileType = Self.fileType(for: finalURL)
        if outputFileType == .caf {
            try Self.concatenateCAFSegments(segmentURLs, to: finalURL)
            for segmentURL in segmentURLs {
                try? fileManager.removeItem(at: segmentURL)
            }
            return finalURL
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw SidecarFailure(code: -32066, message: "Failed to merge audio segments.")
        }

        var cursor = CMTime.zero
        for segmentURL in segmentURLs {
            let asset = AVURLAsset(url: segmentURL)
            let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = sourceTracks.first else {
                throw SidecarFailure(code: -32066, message: "Failed to merge audio segments.")
            }

            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            try track.insertTimeRange(range, of: sourceTrack, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw SidecarFailure(code: -32066, message: "Failed to merge audio segments.")
        }

        try await exporter.export(to: finalURL, as: outputFileType)

        for segmentURL in segmentURLs {
            try? fileManager.removeItem(at: segmentURL)
        }

        return finalURL
    }

    private func makeSegmentURL(index: Int) -> URL {
        let baseName = finalURL.deletingPathExtension().lastPathComponent
        let ext = finalURL.pathExtension.isEmpty ? "m4a" : finalURL.pathExtension
        let segmentName = "\(baseName)-segment-\(String(format: "%03d", index)).\(ext)"
        return finalURL.deletingLastPathComponent().appendingPathComponent(segmentName)
    }

    private static func fileType(for url: URL) -> AVFileType {
        url.pathExtension.lowercased() == "caf" ? .caf : .m4a
    }

    private static func outputSettings(for format: CaptureStreamFormat, fileType: AVFileType) -> [String: Any] {
        if fileType == .caf {
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }

        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: format.recommendedBitRate,
        ]
    }

    private static func concatenateCAFSegments(_ segmentURLs: [URL], to finalURL: URL) throws {
        guard let firstURL = segmentURLs.first else { return }
        let firstFile = try AVAudioFile(forReading: firstURL)
        guard let fileFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: firstFile.fileFormat.sampleRate,
            channels: firstFile.fileFormat.channelCount,
            interleaved: true
        ),
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: firstFile.fileFormat.sampleRate,
                channels: firstFile.fileFormat.channelCount,
                interleaved: false
            )
        else {
            throw SidecarFailure(code: -32066, message: "Failed to merge audio segments.")
        }
        let output = try AVAudioFile(
            forWriting: finalURL,
            settings: fileFormat.settings,
            commonFormat: targetFormat.commonFormat,
            interleaved: targetFormat.isInterleaved
        )
        for segmentURL in segmentURLs {
            try appendAudioFile(at: segmentURL, to: output, targetFormat: targetFormat)
        }
    }

    private static func appendAudioFile(at url: URL, to output: AVAudioFile, targetFormat: AVAudioFormat) throws {
        let input = try AVAudioFile(forReading: url)
        let sourceFormat = input.processingFormat
        let chunkSize: AVAudioFrameCount = 4_096

        while input.framePosition < input.length {
            let remaining = input.length - input.framePosition
            let frameCount = AVAudioFrameCount(min(Int64(chunkSize), remaining))
            guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
                throw SidecarFailure(code: -32066, message: "Failed to merge audio segments.")
            }
            try input.read(into: sourceBuffer, frameCount: frameCount)
            guard sourceBuffer.frameLength > 0 else { continue }

            if sourceFormat.recappiMatches(targetFormat) {
                try output.write(from: sourceBuffer)
                continue
            }

            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw SidecarFailure(code: -32066, message: "Failed to merge audio segments.")
            }
            let convertedCapacity = AVAudioFrameCount(
                ceil(Double(sourceBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate) + 32
            )
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: max(convertedCapacity, 1)
            ) else {
                throw SidecarFailure(code: -32066, message: "Failed to merge audio segments.")
            }

            let inputState = AudioFileConverterInputState(source: sourceBuffer)
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                inputState.next(status: inputStatus)
            }
            guard conversionError == nil, status != .error else {
                throw SidecarFailure(code: -32066, message: "Failed to merge audio segments.")
            }
            if converted.frameLength > 0 {
                try output.write(from: converted)
            }
        }
    }
}

private final class AudioFileConverterInputState: @unchecked Sendable {
    private let source: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideInput = false

    init(source: AVAudioPCMBuffer) {
        self.source = source
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !didProvideInput else {
            status.pointee = .noDataNow
            return nil
        }
        didProvideInput = true
        status.pointee = .haveData
        return source
    }
}

private extension AVAudioFormat {
    func recappiMatches(_ other: AVAudioFormat) -> Bool {
        commonFormat == other.commonFormat
            && abs(sampleRate - other.sampleRate) < 0.1
            && channelCount == other.channelCount
            && isInterleaved == other.isInterleaved
    }
}

private enum AudioMixer {
    private static func outputSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
    }

    static func mix(sources: [URL], to destination: URL) async throws {
        let readable = try sources.map { try AVAudioFile(forReading: $0) }
        guard !readable.isEmpty else {
            throw SidecarFailure(code: -32033, message: "No audio was captured.")
        }

        try await Task.detached(priority: .userInitiated) {
            try runOfflineRender(files: readable, destination: destination)
        }.value
    }

    private static func runOfflineRender(files: [AVAudioFile], destination: URL) throws {
        let engine = AVAudioEngine()
        let mainMixer = engine.mainMixerNode
        mainMixer.outputVolume = files.count > 1 ? 0.5 : 1.0

        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw SidecarFailure(code: -32066, message: "Failed to merge audio sources.")
        }

        try engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4_096)

        var players: [(AVAudioPlayerNode, AVAudioFile)] = []
        for file in files {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: mainMixer, format: file.processingFormat)
            players.append((player, file))
        }

        let outputFile = try AVAudioFile(forWriting: destination, settings: outputSettings())

        try engine.start()
        for (player, file) in players {
            player.scheduleFile(file, at: nil)
            player.play()
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: 4_096) else {
            throw SidecarFailure(code: -32066, message: "Failed to merge audio sources.")
        }

        let maxFrames = players
            .map { _, file in
                AVAudioFramePosition(Double(file.length) * renderFormat.sampleRate / file.processingFormat.sampleRate)
            }
            .max() ?? 0

        renderLoop: while engine.manualRenderingSampleTime < maxFrames {
            let remaining = maxFrames - engine.manualRenderingSampleTime
            let toRender = min(AVAudioFrameCount(remaining), buffer.frameCapacity)

            let status = try engine.renderOffline(toRender, to: buffer)
            switch status {
            case .success, .insufficientDataFromInputNode:
                if buffer.frameLength > 0 {
                    try outputFile.write(from: buffer)
                } else if status == .insufficientDataFromInputNode {
                    break renderLoop
                }
            case .cannotDoInCurrentContext, .error:
                throw SidecarFailure(code: -32066, message: "Failed to merge audio sources.")
            @unknown default:
                throw SidecarFailure(code: -32066, message: "Failed to merge audio sources.")
            }
        }

        for (player, _) in players { player.stop() }
        engine.stop()
    }
}

private extension Dictionary where Key == String, Value == Any {
    func compactJSON() -> [String: Any] {
        filter { !($0.value is NSNull) }.reduce(into: [:]) { partial, pair in
            partial[pair.key] = pair.value
        }
    }
}
