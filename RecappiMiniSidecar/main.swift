import AppKit
import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
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
                    "capabilities": ["recording.capture", "live_captions.stream"],
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
                    },
                    onLiveCaption: { [weak self] sessionID, delta in
                        self?.emitLiveCaptionDelta(sessionID: sessionID, delta: delta)
                    },
                    onError: { [weak self] sessionID, code, message, retryable in
                        self?.emitSessionError(
                            sessionID: sessionID,
                            code: code,
                            message: message,
                            retryable: retryable
                        )
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

    private func emitLiveCaptionDelta(sessionID: String, delta: SidecarLiveCaptionDelta) {
        var params: [String: Any] = [
            "type": "live_caption.delta",
            "sessionId": sessionID,
            "stream": delta.stream.rawValue,
            "text": delta.text,
            "isFinal": delta.isFinal,
        ]
        if let segmentId = delta.segmentId {
            params["segmentId"] = segmentId
        }
        if let language = delta.language {
            params["language"] = language
        }
        writeJSON([
            "jsonrpc": "2.0",
            "method": "recappi.event",
            "params": params,
        ])
    }

    private func emitSessionError(
        sessionID: String,
        code: String,
        message: String,
        retryable: Bool
    ) {
        writeJSON([
            "jsonrpc": "2.0",
            "method": "recappi.event",
            "params": [
                "type": "error",
                "sessionId": sessionID,
                "code": code,
                "message": message,
                "retryable": retryable,
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
    let transcriptionLanguage: String?
    let translationLanguage: String?
    let title: String?

    init(_ raw: [String: Any]) {
        includeSystemAudio = raw["includeSystemAudio"] as? Bool ?? true
        includeMicrophone = raw["includeMicrophone"] as? Bool ?? true
        targetBundleId = raw["targetBundleId"] as? String
        microphoneDeviceId = raw["microphoneDeviceId"] as? String
        liveCaptions = raw["liveCaptions"] as? Bool ?? false
        transcriptionLanguage = raw["transcriptionLanguage"] as? String
        translationLanguage = raw["translationLanguage"] as? String
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
    private let onLiveCaption: (String, SidecarLiveCaptionDelta) -> Void
    private let onError: (String, String, String, Bool) -> Void
    private(set) var state: RecordingState = .idle
    private(set) var sessionDir: URL?
    private var coreSession: CaptureAudioRecordingSession?
    private var liveCaptionStreamer: SidecarLiveCaptionStreamer?
    private var stateTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?

    init(
        options: RecordingOptions,
        account: [String: Any],
        onState: @escaping (SidecarRecordingSession, RecordingState, String?) -> Void,
        onLevel: @escaping (String, CaptureLevel) -> Void,
        onLiveCaption: @escaping (String, SidecarLiveCaptionDelta) -> Void,
        onError: @escaping (String, String, String, Bool) -> Void
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
        self.onLiveCaption = onLiveCaption
        self.onError = onError
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
        let streamer = makeLiveCaptionStreamer()
        liveCaptionStreamer = streamer
        streamer?.start()

        let coreSession = CaptureAudioRecordingSession(configuration: CaptureAudioRecordingSessionConfiguration(
            sessionID: id,
            sessionDirectoryURL: dir,
            includeSystemAudio: options.includeSystemAudio,
            targetBundleID: options.targetBundleId,
            includeMicrophone: options.includeMicrophone,
            microphoneDeviceID: options.microphoneDeviceId,
            metadata: CaptureSessionMetadata(sessionID: id, title: options.title),
            sampleBufferTap: { [weak streamer] input, sampleBuffer in
                streamer?.append(input: input, sampleBuffer: sampleBuffer)
            }
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
        liveCaptionStreamer?.stop()
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
        self.liveCaptionStreamer = nil
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
        liveCaptionStreamer?.stop()
        await waitForForwarders()
        state = .cancelled
        if let sessionDir {
            try? FileManager.default.removeItem(at: sessionDir)
        }
        coreSession = nil
        liveCaptionStreamer = nil
        sessionDir = nil
    }

    private func makeLiveCaptionStreamer() -> SidecarLiveCaptionStreamer? {
        guard options.liveCaptions else { return nil }
        guard let backendOrigin = account["backendOrigin"] as? String,
              let authToken = account["authToken"] as? String,
              !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            onError(
                id,
                "live_caption.auth_missing",
                "Sign in to Recappi before using live captions.",
                false
            )
            return nil
        }
        return SidecarLiveCaptionStreamer(
            sessionID: id,
            backendOrigin: backendOrigin,
            authToken: authToken,
            options: options,
            onDelta: { [weak self] delta in
                guard let self else { return }
                self.onLiveCaption(self.id, delta)
            },
            onError: { [weak self] code, message, retryable in
                guard let self else { return }
                self.onError(self.id, code, message, retryable)
            }
        )
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

private struct SidecarLiveCaptionDelta: Sendable {
    enum Stream: String, Sendable {
        case source
        case translation
    }

    let stream: Stream
    let text: String
    let isFinal: Bool
    let segmentId: String?
    let language: String?
}

private final class SidecarLiveCaptionStreamer: @unchecked Sendable {
    private enum Mode {
        case transcription
        case translation(targetLanguage: String)

        var isTranslation: Bool {
            if case .translation = self { return true }
            return false
        }
    }

    private struct RealtimeClaim: Decodable {
        let sessionId: String
        let websocketUrl: String
        let token: String
        let tokenType: String
    }

    private struct RealtimeReceiveEvent: Decodable {
        let type: String
        let itemID: String?
        let contentIndex: Int?
        let delta: String?
        let transcript: String?
        let error: RealtimeReceiveError?

        var segmentId: String {
            guard let itemID, !itemID.isEmpty else { return "current" }
            if let contentIndex, contentIndex != 0 {
                return "\(itemID)#\(contentIndex)"
            }
            return itemID
        }

        enum CodingKeys: String, CodingKey {
            case type
            case itemID = "item_id"
            case contentIndex = "content_index"
            case delta
            case transcript
            case error
        }
    }

    private struct RealtimeReceiveError: Decodable {
        let message: String?
    }

    private struct Failure: Error {
        let message: String
    }

    private static let manualCommitByteThreshold = 67_200

    private let sessionID: String
    private let backendOrigin: String
    private let authToken: String
    private let options: RecordingOptions
    private let mode: Mode
    private let onDelta: (SidecarLiveCaptionDelta) -> Void
    private let onError: (String, String, Bool) -> Void
    private let urlSession: URLSession
    private let sendQueue = DispatchQueue(label: "com.recappi.sidecar.live-caption.send")
    private let lock = NSLock()

    private var socket: URLSessionWebSocketTask?
    private var stopped = false
    private var uncommittedAudioBytes = 0
    private var transcriptTextBySegment: [String: String] = [:]
    private var translationSourceText = ""
    private var translationText = ""

    init(
        sessionID: String,
        backendOrigin: String,
        authToken: String,
        options: RecordingOptions,
        onDelta: @escaping (SidecarLiveCaptionDelta) -> Void,
        onError: @escaping (String, String, Bool) -> Void
    ) {
        self.sessionID = sessionID
        self.backendOrigin = backendOrigin
        self.authToken = authToken
        self.options = options
        let targetLanguage = options.translationLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let targetLanguage, !targetLanguage.isEmpty {
            mode = .translation(targetLanguage: targetLanguage)
        } else {
            mode = .transcription
        }
        self.onDelta = onDelta
        self.onError = onError
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config)
    }

    func start() {
        Task { [weak self] in
            await self?.open()
        }
    }

    func append(input: CaptureLevel.Input, sampleBuffer: CMSampleBuffer) {
        guard shouldCaption(input: input),
              let payload = autoreleasepool(invoking: {
                  SidecarRealtimeAudioEncoder.pcm16Data(from: sampleBuffer)
              }),
              !payload.isEmpty
        else {
            return
        }
        sendAudio(payload)
    }

    func stop() {
        let task: URLSessionWebSocketTask?
        lock.lock()
        stopped = true
        task = socket
        socket = nil
        let shouldCommit = !mode.isTranslation && uncommittedAudioBytes > 0
        uncommittedAudioBytes = 0
        lock.unlock()

        emitFinalPartials()
        if shouldCommit {
            sendRawText(Self.commitEventText, task: task)
        }
        if mode.isTranslation {
            sendRawText(Self.sessionCloseEventText, task: task)
        }
        task?.cancel(with: .goingAway, reason: nil)
        urlSession.invalidateAndCancel()
    }

    private func open() async {
        do {
            let claim = try await claimSession()
            guard let websocketURL = URL(string: claim.websocketUrl) else {
                throw Failure(message: "Live captions returned an invalid websocket URL.")
            }
            var request = URLRequest(url: websocketURL)
            request.timeoutInterval = 60
            request.setValue("\(claim.tokenType) \(claim.token)", forHTTPHeaderField: "Authorization")
            request.setValue(backendOrigin, forHTTPHeaderField: "Origin")
            let task = urlSession.webSocketTask(with: request)
            if !installSocket(task) {
                task.cancel(with: .goingAway, reason: nil)
                return
            }
            task.resume()
            receiveLoop(task)
            _ = claim.sessionId
        } catch {
            emitError(
                code: "live_caption.connect_failed",
                message: "Live captions could not connect.",
                retryable: true
            )
        }
    }

    private func installSocket(_ task: URLSessionWebSocketTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        socket = task
        return true
    }

    private func claimSession() async throws -> RealtimeClaim {
        guard let url = URL(string: "\(backendOrigin)/api/openai/realtime/sessions") else {
            throw Failure(message: "Invalid Recappi backend URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpShouldHandleCookies = false
        request.setValue(backendOrigin, forHTTPHeaderField: "Origin")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: claimRequestBody())
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw Failure(message: "Live captions claim failed.")
        }
        return try JSONDecoder().decode(RealtimeClaim.self, from: data)
    }

    private func claimRequestBody() -> [String: Any] {
        let language = options.transcriptionLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .transcription:
            return [
                "mode": "transcription",
                "language": language?.isEmpty == false ? language! : "en-US",
                "delay": "low",
                "expiresAfterSeconds": 60,
                "turnDetection": ["type": "none"],
            ]
        case .translation(let targetLanguage):
            return [
                "mode": "translation",
                "language": language?.isEmpty == false ? language! : "en",
                "targetLanguage": targetLanguage,
                "delay": "low",
                "expiresAfterSeconds": 60,
                "includeSourceTranscript": true,
            ]
        }
    }

    private func shouldCaption(input: CaptureLevel.Input) -> Bool {
        switch input {
        case .system:
            return options.includeSystemAudio
        case .microphone:
            return !options.includeSystemAudio && options.includeMicrophone
        }
    }

    private func sendAudio(_ payload: Data) {
        let eventType = mode.isTranslation
            ? "session.input_audio_buffer.append"
            : "input_audio_buffer.append"
        sendText(Self.audioAppendEventText(eventType: eventType, payload: payload))
        guard !mode.isTranslation else { return }

        var shouldCommit = false
        lock.lock()
        uncommittedAudioBytes += payload.count
        if uncommittedAudioBytes >= Self.manualCommitByteThreshold {
            uncommittedAudioBytes = 0
            shouldCommit = true
        }
        lock.unlock()
        if shouldCommit {
            sendText(Self.commitEventText)
        }
    }

    private func sendText(_ text: String) {
        let task: URLSessionWebSocketTask?
        lock.lock()
        task = socket
        lock.unlock()
        sendRawText(text, task: task)
    }

    private func sendRawText(_ text: String, task: URLSessionWebSocketTask?) {
        guard let task else { return }
        let streamer = self
        sendQueue.async {
            task.send(.string(text)) { error in
                if error != nil {
                    streamer.emitError(
                        code: "live_caption.send_failed",
                        message: "Live captions connection dropped.",
                        retryable: true
                    )
                }
            }
        }
    }

    private static func audioAppendEventText(eventType: String, payload: Data) -> String {
        "{\"type\":\"\(eventType)\",\"audio\":\"\(payload.base64EncodedString())\"}"
    }

    private static let commitEventText = "{\"type\":\"input_audio_buffer.commit\"}"
    private static let sessionCloseEventText = "{\"type\":\"session.close\"}"

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let task else { return }
            switch result {
            case .success(let message):
                self.handle(message: message)
                if !self.isStopped {
                    self.receiveLoop(task)
                }
            case .failure:
                if !self.isStopped {
                    self.emitError(
                        code: "live_caption.receive_failed",
                        message: "Live captions connection dropped.",
                        retryable: true
                    )
                }
            }
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let value):
            data = value
        @unknown default:
            return
        }
        guard let event = try? JSONDecoder().decode(RealtimeReceiveEvent.self, from: data) else {
            return
        }
        switch event.type {
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = event.delta, !delta.isEmpty else { return }
            let segmentId = event.segmentId
            let text = append(delta, toTranscriptSegment: segmentId)
            emitDelta(stream: .source, text: text, isFinal: false, segmentId: segmentId)
        case "conversation.item.input_audio_transcription.completed":
            let segmentId = event.segmentId
            let text = (event.transcript?.isEmpty == false ? event.transcript : transcriptTextBySegment[segmentId]) ?? ""
            guard !text.isEmpty else { return }
            transcriptTextBySegment[segmentId] = text
            emitDelta(stream: .source, text: text, isFinal: true, segmentId: segmentId)
        case "session.input_transcript.delta":
            guard let delta = event.delta, !delta.isEmpty else { return }
            appendDisplayText(delta, to: &translationSourceText)
            emitDelta(
                stream: .source,
                text: translationSourceText,
                isFinal: false,
                segmentId: "translation-current"
            )
        case "session.output_transcript.delta":
            guard let delta = event.delta, !delta.isEmpty else { return }
            appendDisplayText(delta, to: &translationText)
            emitDelta(
                stream: .translation,
                text: translationText,
                isFinal: false,
                segmentId: "translation-current"
            )
        case "error":
            emitError(
                code: "live_caption.server_error",
                message: event.error?.message ?? "Live captions failed.",
                retryable: true
            )
        default:
            break
        }
    }

    private func append(_ delta: String, toTranscriptSegment segmentId: String) -> String {
        var current = transcriptTextBySegment[segmentId] ?? ""
        appendDisplayText(delta, to: &current)
        transcriptTextBySegment[segmentId] = current
        return current
    }

    private func appendDisplayText(_ fragment: String, to result: inout String) {
        guard !fragment.isEmpty else { return }
        guard let previous = result.last, let next = fragment.first else {
            result.append(fragment)
            return
        }
        if shouldInsertDisplaySpace(between: previous, and: next) {
            result.append(" ")
        }
        result.append(fragment)
    }

    private func shouldInsertDisplaySpace(between previous: Character, and next: Character) -> Bool {
        if previous.isWhitespace || next.isWhitespace { return false }
        if next.isPunctuation || next.isSymbol { return false }
        if previous.isCJK || next.isCJK { return false }
        if previous.isPunctuation || previous.isSymbol {
            return previous.prefersFollowingLiveCaptionWordSpace
        }
        return true
    }

    private func emitFinalPartials() {
        if !translationSourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emitDelta(
                stream: .source,
                text: translationSourceText,
                isFinal: true,
                segmentId: "translation-current"
            )
        }
        if !translationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emitDelta(
                stream: .translation,
                text: translationText,
                isFinal: true,
                segmentId: "translation-current"
            )
        }
    }

    private func emitDelta(
        stream: SidecarLiveCaptionDelta.Stream,
        text: String,
        isFinal: Bool,
        segmentId: String
    ) {
        onDelta(SidecarLiveCaptionDelta(
            stream: stream,
            text: text,
            isFinal: isFinal,
            segmentId: segmentId,
            language: language(for: stream)
        ))
    }

    private func language(for stream: SidecarLiveCaptionDelta.Stream) -> String? {
        let value: String?
        switch stream {
        case .source:
            value = options.transcriptionLanguage
        case .translation:
            value = options.translationLanguage
        }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func emitError(code: String, message: String, retryable: Bool) {
        onError(code, message, retryable)
    }
}

private extension Character {
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    var prefersFollowingLiveCaptionWordSpace: Bool {
        self == "." || self == "," || self == ":" || self == ";" || self == "!" || self == "?"
    }
}

private enum SidecarRealtimeAudioEncoder {
    static let targetSampleRate: Double = 24_000

    static func pcm16Data(from sampleBuffer: CMSampleBuffer) -> Data? {
        if let direct = directHalfRatePCM16Data(from: sampleBuffer) {
            return direct
        }

        guard let source = floatingPCMBuffer(from: sampleBuffer),
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: targetSampleRate,
                  channels: 1,
                  interleaved: true
              ),
              let converter = AVAudioConverter(from: source.format, to: targetFormat)
        else {
            return nil
        }

        let ratio = targetSampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * ratio) + 16)
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        let inputState = SidecarRealtimeConverterInputState(source: source)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            inputState.next(status: status)
        }
        guard error == nil,
              converted.frameLength > 0,
              let data = converted.int16ChannelData
        else {
            return nil
        }

        let byteCount = Int(converted.frameLength) * Int(converted.format.streamDescription.pointee.mBytesPerFrame)
        return Data(bytes: data[0], count: byteCount)
    }

    private static func directHalfRatePCM16Data(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard sampleBuffer.isValid,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        let asbd = asbdPointer.pointee
        guard abs(asbd.mSampleRate - (targetSampleRate * 2)) < 1 else {
            return nil
        }

        let channelCount = max(Int(asbd.mChannelsPerFrame), 1)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let outputFrameCount = frameCount / 2
        guard outputFrameCount > 0 else { return nil }

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
            return nil
        }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if isFloat, asbd.mBitsPerChannel == 32 {
            let sampleCount = min(totalLength / MemoryLayout<Float>.size, frameCount * channelCount)
            return raw.withMemoryRebound(to: Float.self, capacity: sampleCount) { source in
                var output = Data(count: outputFrameCount * MemoryLayout<Int16>.size)
                output.withUnsafeMutableBytes { rawOutput in
                    guard let target = rawOutput.bindMemory(to: Int16.self).baseAddress else { return }
                    var outputFrame = 0
                    if isNonInterleaved {
                        while outputFrame < outputFrameCount {
                            let firstFrame = outputFrame * 2
                            let secondFrame = firstFrame + 1
                            var mixed: Float = 0
                            var channel = 0
                            while channel < channelCount {
                                let channelBase = channel * frameCount
                                let firstIndex = channelBase + firstFrame
                                let secondIndex = channelBase + secondFrame
                                let first = firstIndex < sampleCount ? source[firstIndex] : 0
                                let second = secondIndex < sampleCount ? source[secondIndex] : 0
                                mixed += (first + second) * 0.5
                                channel += 1
                            }
                            target[outputFrame] = pcm16Sample(mixed / Float(channelCount))
                            outputFrame += 1
                        }
                    } else {
                        while outputFrame < outputFrameCount {
                            let firstBase = (outputFrame * 2) * channelCount
                            let secondBase = firstBase + channelCount
                            var mixed: Float = 0
                            var channel = 0
                            while channel < channelCount {
                                let firstIndex = firstBase + channel
                                let secondIndex = secondBase + channel
                                let first = firstIndex < sampleCount ? source[firstIndex] : 0
                                let second = secondIndex < sampleCount ? source[secondIndex] : 0
                                mixed += (first + second) * 0.5
                                channel += 1
                            }
                            target[outputFrame] = pcm16Sample(mixed / Float(channelCount))
                            outputFrame += 1
                        }
                    }
                }
                return output
            }
        }

        if asbd.mBitsPerChannel == 16 {
            let sampleCount = min(totalLength / MemoryLayout<Int16>.size, frameCount * channelCount)
            return raw.withMemoryRebound(to: Int16.self, capacity: sampleCount) { source in
                var output = Data(count: outputFrameCount * MemoryLayout<Int16>.size)
                output.withUnsafeMutableBytes { rawOutput in
                    guard let target = rawOutput.bindMemory(to: Int16.self).baseAddress else { return }
                    var outputFrame = 0
                    if isNonInterleaved {
                        while outputFrame < outputFrameCount {
                            let firstFrame = outputFrame * 2
                            let secondFrame = firstFrame + 1
                            var mixed = 0
                            var observedSamples = 0
                            var channel = 0
                            while channel < channelCount {
                                let channelBase = channel * frameCount
                                let firstIndex = channelBase + firstFrame
                                if firstIndex < sampleCount {
                                    mixed += Int(source[firstIndex])
                                    observedSamples += 1
                                }
                                let secondIndex = channelBase + secondFrame
                                if secondIndex < sampleCount {
                                    mixed += Int(source[secondIndex])
                                    observedSamples += 1
                                }
                                channel += 1
                            }
                            target[outputFrame] = observedSamples > 0
                                ? Int16(clamping: mixed / observedSamples)
                                : 0
                            outputFrame += 1
                        }
                    } else {
                        while outputFrame < outputFrameCount {
                            let firstBase = (outputFrame * 2) * channelCount
                            let secondBase = firstBase + channelCount
                            var mixed = 0
                            var observedSamples = 0
                            var channel = 0
                            while channel < channelCount {
                                let firstIndex = firstBase + channel
                                if firstIndex < sampleCount {
                                    mixed += Int(source[firstIndex])
                                    observedSamples += 1
                                }
                                let secondIndex = secondBase + channel
                                if secondIndex < sampleCount {
                                    mixed += Int(source[secondIndex])
                                    observedSamples += 1
                                }
                                channel += 1
                            }
                            target[outputFrame] = observedSamples > 0
                                ? Int16(clamping: mixed / observedSamples)
                                : 0
                            outputFrame += 1
                        }
                    }
                }
                return output
            }
        }

        return nil
    }

    private static func pcm16Sample(_ value: Float) -> Int16 {
        let clamped = min(max(value, -1), 1)
        return Int16(clamping: Int((clamped * 32_767).rounded()))
    }

    private static func floatingPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            return nil
        }

        let asbd = asbdPointer.pointee
        let channelCount = max(Int(asbd.mChannelsPerFrame), 1)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: asbd.mSampleRate,
                  channels: AVAudioChannelCount(channelCount),
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              )
        else {
            return nil
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
        guard status == kCMBlockBufferNoErr,
              let raw = dataPointer,
              let channels = buffer.floatChannelData
        else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        if isFloat, asbd.mBitsPerChannel == 32 {
            let sampleCount = min(totalLength / MemoryLayout<Float>.size, frameCount * channelCount)
            raw.withMemoryRebound(to: Float.self, capacity: sampleCount) { source in
                copySamples(
                    source: source,
                    sampleCount: sampleCount,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    isNonInterleaved: isNonInterleaved,
                    channels: channels
                )
            }
        } else if asbd.mBitsPerChannel == 16 {
            let sampleCount = min(totalLength / MemoryLayout<Int16>.size, frameCount * channelCount)
            raw.withMemoryRebound(to: Int16.self, capacity: sampleCount) { source in
                for frame in 0..<frameCount {
                    for channel in 0..<channelCount {
                        let index = sourceIndex(
                            frame: frame,
                            channel: channel,
                            frameCount: frameCount,
                            channelCount: channelCount,
                            isNonInterleaved: isNonInterleaved
                        )
                        let sample = index < sampleCount ? source[index] : 0
                        channels[channel][frame] = Float(sample) / Float(Int16.max)
                    }
                }
            }
        } else {
            return nil
        }

        return buffer
    }

    private static func copySamples(
        source: UnsafePointer<Float>,
        sampleCount: Int,
        frameCount: Int,
        channelCount: Int,
        isNonInterleaved: Bool,
        channels: UnsafePointer<UnsafeMutablePointer<Float>>
    ) {
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let index = sourceIndex(
                    frame: frame,
                    channel: channel,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    isNonInterleaved: isNonInterleaved
                )
                channels[channel][frame] = index < sampleCount ? source[index] : 0
            }
        }
    }

    private static func sourceIndex(
        frame: Int,
        channel: Int,
        frameCount: Int,
        channelCount: Int,
        isNonInterleaved: Bool
    ) -> Int {
        if isNonInterleaved {
            return (channel * frameCount) + frame
        }
        return (frame * channelCount) + channel
    }
}

private final class SidecarRealtimeConverterInputState: @unchecked Sendable {
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
