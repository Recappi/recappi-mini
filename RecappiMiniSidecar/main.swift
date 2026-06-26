import AppKit
import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation
import RecappiCaptureCore

private let protocolVersion = 1
private let sidecarName = "recappi-mini-sidecar"
private let sidecarVersion =
    ProcessInfo.processInfo.environment["RECAPPI_SIDECAR_VERSION"]
    ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    ?? "0.1.0"

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
    private let outputLock = NSLock()

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
                    "sources": await RecordingInputCatalog.sources(),
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
                let session = try await SidecarRecordingSession(
                    options: options,
                    account: account,
                    onState: { [weak self] session, state, message in
                        self?.emitRecordingState(session, override: state, message: message)
                    },
                    onLevel: { [weak self] sessionID, level in
                        self?.emitAudioLevel(sessionID: sessionID, level: level)
                    }
                )
                try await session.start()
                activeSession = session
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
            case "recappi.shutdown":
                result(id: id, ["ok": true])
                Foundation.exit(0)
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
        artifact: LocalArtifact? = nil,
        message: String? = nil
    ) {
        var params: [String: Any] = [
            "type": "recording.state",
            "sessionId": session.id,
            "state": (override ?? session.state).rawValue,
        ]
        if let message {
            params["message"] = message
        }
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

    private func emitAudioLevel(sessionID: String, level: CaptureLevel) {
        writeJSON([
            "jsonrpc": "2.0",
            "method": "recappi.event",
            "params": [
                "type": "audio.level",
                "sessionId": sessionID,
                "input": level.input.rawValue,
                "rmsDb": Double(level.rmsDb),
                "atMs": level.atMs,
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
        outputLock.lock()
        defer { outputLock.unlock() }
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

private extension CaptureSource {
    var json: [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "kind": kind.rawValue,
            "label": label,
        ]
        if let appName {
            payload["appName"] = appName
        }
        if let bundleID {
            payload["bundleId"] = bundleID
        }
        return payload
    }
}

private enum RecordingInputCatalog {
    static func sources() async -> [[String: Any]] {
        let selfBundleID = Bundle.main.bundleIdentifier ?? "com.recappi.recorder"
        if let sources = try? await CaptureSourceCatalog.availableSources(selfBundleID: selfBundleID) {
            return sources.map(\.json)
        }

        return workspaceSources(selfBundleID: selfBundleID).map(\.json)
    }

    private static func workspaceSources(selfBundleID: String) -> [CaptureSource] {
        var seen = Set<String>()
        let applications = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular && app.isTerminated == false && app.bundleIdentifier != nil
            }
            .sorted { lhs, rhs in
                (lhs.localizedName ?? lhs.bundleIdentifier ?? "") < (rhs.localizedName ?? rhs.bundleIdentifier ?? "")
            }
            .compactMap { app -> CaptureSourceApplication? in
                guard let bundleID = app.bundleIdentifier,
                      seen.insert(bundleID).inserted,
                      CoreAudioProcessResolver.processObjectID(pid: app.processIdentifier) != nil
                else { return nil }
                return CaptureSourceApplication(
                    bundleID: bundleID,
                    name: app.localizedName ?? bundleID
                )
            }

        return CaptureSourceCatalog.sources(
            from: applications,
            selfBundleID: selfBundleID
        )
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

    init?(captureStatus: CaptureState.Status) {
        switch captureStatus {
        case .idle:
            self = .idle
        case .starting:
            self = .starting
        case .recording:
            self = .recording
        case .paused:
            return nil
        case .stopping:
            self = .stopping
        case .finalizing:
            self = .finalizing
        case .completed:
            self = .completed
        case .failed:
            self = .failed
        case .cancelled:
            self = .cancelled
        }
    }
}

private struct LocalArtifact {
    let sessionDir: URL
    let audioURL: URL
    let options: RecordingOptions
    let durationMs: Int64?
    let diagnostics: [String: String]

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
        if let durationMs {
            metadata["durationMs"] = durationMs
        }
        if let sizeBytes = diagnostics["mixed.byteCount"].flatMap(Int64.init) {
            metadata["sizeBytes"] = sizeBytes
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

private final class SidecarRecordingSession: @unchecked Sendable {
    let id = UUID().uuidString
    let options: RecordingOptions
    let account: [String: Any]
    private let onState: (SidecarRecordingSession, RecordingState, String?) -> Void
    private let onLevel: (String, CaptureLevel) -> Void
    private(set) var state: RecordingState = .idle
    private(set) var sessionDir: URL?
    private var coreSession: CaptureAudioRecordingSession?
    private var stateTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?

    init(
        options: RecordingOptions,
        account: [String: Any],
        onState: @escaping (SidecarRecordingSession, RecordingState, String?) -> Void,
        onLevel: @escaping (String, CaptureLevel) -> Void
    ) async throws {
        guard options.includeSystemAudio || options.includeMicrophone else {
            throw SidecarFailure(
                code: -32021,
                message: "Choose at least one audio source before starting a recording.",
                data: ["cliCode": "usage.invalid_argument"]
            )
        }
        self.options = options
        self.account = account
        self.onState = onState
        self.onLevel = onLevel
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

        let coreSession = CaptureAudioRecordingSession(configuration: CaptureAudioRecordingSessionConfiguration(
            sessionID: id,
            sessionDirectoryURL: dir,
            includeSystemAudio: options.includeSystemAudio,
            targetBundleID: options.targetBundleId,
            includeMicrophone: options.includeMicrophone,
            microphoneDeviceID: options.microphoneDeviceId,
            metadata: CaptureSessionMetadata(sessionID: id, title: options.title)
        ))
        self.coreSession = coreSession
        forwardEvents(from: coreSession)

        try await coreSession.start()
        state = .recording
    }

    func stop() async throws -> StoppedRecording {
        guard state == .recording else {
            throw SidecarFailure(code: -32032, message: "Recappi CLI recording is not currently running.")
        }
        guard let coreSession else {
            throw SidecarFailure(code: -32032, message: "Recappi CLI recording is not currently running.")
        }
        guard let sessionDir else {
            throw SidecarFailure(code: -32034, message: "Recording session directory is missing.")
        }

        let artifact = try await coreSession.stop()
        await waitForForwarders()
        guard let audioURL = artifact.mixedAudioURL else {
            throw SidecarFailure(
                code: -32033,
                message: "No audio was captured. Check macOS permissions and make sure audio is playing before trying again.",
                data: ["cliCode": "record.capture_failed"]
            )
        }
        state = .completed
        self.coreSession = nil
        return StoppedRecording(
            artifact: LocalArtifact(
                sessionDir: sessionDir,
                audioURL: audioURL,
                options: options,
                durationMs: artifact.durationMs,
                diagnostics: artifact.diagnostics
            )
        )
    }

    func cancel() async {
        await coreSession?.cancel()
        await waitForForwarders()
        state = .cancelled
        if let sessionDir {
            try? FileManager.default.removeItem(at: sessionDir)
        }
        coreSession = nil
        sessionDir = nil
    }

    private func forwardEvents(from coreSession: CaptureAudioRecordingSession) {
        let states = coreSession.states
        stateTask = Task { [weak self] in
            for await captureState in states {
                guard let self,
                      let recordingState = RecordingState(captureStatus: captureState.status)
                else { continue }
                self.state = recordingState
                guard recordingState != .completed else { continue }
                self.onState(self, recordingState, captureState.message)
            }
        }

        let levels = coreSession.levels
        levelTask = Task { [weak self] in
            for await level in levels {
                guard let self else { continue }
                self.onLevel(self.id, level)
            }
        }
    }

    private func waitForForwarders() async {
        await stateTask?.value
        await levelTask?.value
        stateTask = nil
        levelTask = nil
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
    static func status(options: RecordingOptions) -> [[String: Any]] {
        var permissions: [[String: Any]] = []
        if options.includeSystemAudio {
            let granted = CGPreflightScreenCaptureAccess()
            permissions.append([
                "name": "screen_recording",
                "status": granted ? "granted" : "unknown",
                "hint": "Open System Settings > Privacy & Security > Screen Recording, turn on Recappi Recorder, then run recappi record again.",
            ])
        }
        if options.includeMicrophone {
            permissions.append([
                "name": "microphone",
                "status": microphoneStatus(),
                "hint": "Open System Settings > Privacy & Security > Microphone, turn on Recappi Recorder, then run recappi record again.",
            ])
        }
        return permissions
    }

    static func require(options: RecordingOptions) async throws {
        if options.includeMicrophone {
            try await requireMicrophone()
        }
    }

    private static func requireMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let allowed = await requestMicrophoneAccess()
            if allowed { throw microphoneGrantedRequiresRestart() }
            throw microphoneDenied()
        case .denied, .restricted:
            throw microphoneDenied()
        @unknown default:
            throw microphoneDenied()
        }
    }

    @MainActor
    private static func requestMicrophoneAccess() async -> Bool {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    private static func microphoneDenied() -> SidecarFailure {
        SidecarFailure(
            code: -32020,
            message: "Microphone access is required before the CLI can record microphone audio.",
            data: [
                "cliCode": "record.permission_required",
                "permission": "microphone",
                "recovery": "Open System Settings > Privacy & Security > Microphone, turn on Recappi Recorder, then run recappi record again.",
            ]
        )
    }

    private static func microphoneGrantedRequiresRestart() -> SidecarFailure {
        SidecarFailure(
            code: -32020,
            message: "Microphone access is enabled; restart the local recorder to use it.",
            data: [
                "cliCode": "record.permission_required",
                "permission": "microphone",
                "requiresProcessRestart": "true",
                "recovery": "Microphone enabled. Run recappi record again to start.",
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
        if let error = error as? CaptureAudioError {
            return captureAudio(error)
        }
        if let error = error as? CaptureAudioRecordingSessionError {
            return recordingSession(error)
        }
        return SidecarFailure(
            code: -32050,
            message: error.localizedDescription,
            data: ["cliCode": "record.capture_failed"]
        )
    }

    private static func recordingSession(_ error: CaptureAudioRecordingSessionError) -> SidecarFailure {
        switch error {
        case .noAudioInputs:
            return SidecarFailure(
                code: -32021,
                message: "Choose at least one audio source before starting a recording.",
                data: ["cliCode": "usage.invalid_argument"]
            )
        case .targetApplicationUnavailable:
            return SidecarFailure(
                code: -32043,
                message: "The selected app is no longer available for recording.",
                data: ["cliCode": "record.capture_failed"]
            )
        case .notRecording:
            return SidecarFailure(code: -32032, message: "Recappi CLI recording is not currently running.")
        case .noDisplay, .noMicrophone, .microphoneUnavailable, .microphoneSetupFailed, .pauseUnsupported:
            return SidecarFailure(
                code: -32050,
                message: error.localizedDescription,
                data: ["cliCode": "record.capture_failed"]
            )
        }
    }

    private static func captureAudio(_ error: CaptureAudioError) -> SidecarFailure {
        switch error {
        case .noCapturedAudio:
            return SidecarFailure(
                code: -32033,
                message: "No audio was captured. Check macOS permissions and make sure audio is playing before trying again.",
                data: ["cliCode": "record.capture_failed"]
            )
        case .finishAlreadyRequested:
            return SidecarFailure(
                code: -32062,
                message: "Audio finishing is already in progress.",
                data: ["cliCode": "record.capture_failed"]
            )
        case .failedToCreateAudioInput:
            return SidecarFailure(
                code: -32063,
                message: "Couldn't create the audio writer input.",
                data: ["cliCode": "record.capture_failed"]
            )
        case .failedToStartWriter:
            return SidecarFailure(
                code: -32064,
                message: "Couldn't start the audio writer.",
                data: ["cliCode": "record.capture_failed"]
            )
        case .failedToFinalizeSegment:
            return SidecarFailure(
                code: -32065,
                message: "Couldn't finalize a captured audio segment.",
                data: ["cliCode": "record.capture_failed"]
            )
        case .exportFailed, .sourceUnreadable:
            return SidecarFailure(
                code: -32066,
                message: "Failed to merge audio sources.",
                data: ["cliCode": "record.capture_failed"]
            )
        case .invalidAudioFormat, .failedToAppendAudio:
            return SidecarFailure(
                code: -32061,
                message: "Couldn't append captured audio.",
                data: ["cliCode": "record.capture_failed"]
            )
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

private extension Dictionary where Key == String, Value == Any {
    func compactJSON() -> [String: Any] {
        filter { !($0.value is NSNull) }.reduce(into: [:]) { partial, pair in
            partial[pair.key] = pair.value
        }
    }
}
